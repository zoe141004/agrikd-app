"""Sync engine for pushing predictions to Supabase.

Design principles:
  - LOCAL-FIRST: Main thread captures + infers + saves to SQLite independently.
    This module only handles the "push to cloud" part. If push fails, data stays
    in SQLite and will be retried on next cycle.
  - SINGLE-WRITER (Correction C): Only sync_engine writes to device_state.json.
    main.py and gui_app.py are READ-ONLY consumers (via get_device_state()).
    Writes use exclusive file lock (fcntl) + atomic rename for crash safety.
  - LOOP NEVER STOPS (Correction A): Even when no user_id is assigned, the loop
    keeps running to poll for assignment. Only the POST (cloud push) is skipped.
"""

import json
import logging
import os
import tempfile
import threading
import time
from datetime import datetime, timezone

import requests

# fcntl is Unix-only; graceful fallback for dev/testing on Windows
try:
    import fcntl
    _HAS_FCNTL = True
except ImportError:
    _HAS_FCNTL = False


logger = logging.getLogger("sync")

# Path to device state file (relative to working directory)
_DEVICE_STATE_PATH = os.path.join("data", "device_state.json")


class SyncEngine:
    """Background sync of predictions to Supabase via HTTP POST.

    Authenticates either via:
      1. device_token (X-Device-Token header) — after provisioning
      2. email/password JWT — legacy fallback
    """

    def __init__(self, config, db, models_config=None, shutdown_event=None):
        self.supabase_url = config.get("supabase_url", "")
        self.supabase_key = config.get("supabase_key", "")
        self.email = config.get("email", "")
        self.password = config.get("password", "")
        self.batch_size = config.get("batch_size", 50)
        self.interval = config.get("interval_seconds", 300)
        self.db = db
        self._models_config = models_config or {}
        self._shutdown_event = shutdown_event or threading.Event()

        # JWT auth (legacy)
        self._access_token = ""
        self._user_id = ""

        # Device state: SINGLE-WRITER — only this class writes to file
        self._device_state = self._load_device_state()
        self._state_lock = threading.Lock()

        # Active config from remote (thread-safe read for main.py)
        self._active_config = None
        self._config_lock = threading.Lock()

        if self._device_state:
            logger.info(
                "Device state loaded: device_id=%s, hw_id=%s",
                self._device_state.get("device_id"),
                self._device_state.get("hw_id", "")[:12],
            )

    @property
    def _is_configured(self):
        return bool(self.supabase_url and self.supabase_key)

    # ── Device state (SINGLE-WRITER with file locking) ────────────────

    def _load_device_state(self):
        """Load device_state.json with shared lock and retry.

        Fix 1.8: os.replace() during atomic write creates a brief window
        where the file may not exist.  Retry once after a short delay.
        """
        for attempt in range(2):
            try:
                with open(_DEVICE_STATE_PATH, "r") as f:
                    if _HAS_FCNTL:
                        fcntl.flock(f, fcntl.LOCK_SH)
                    try:
                        state = json.load(f)
                    finally:
                        if _HAS_FCNTL:
                            fcntl.flock(f, fcntl.LOCK_UN)
                    if state.get("device_token") and state.get("device_id"):
                        return state
                    logger.warning("device_state.json missing required fields")
                    return None
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                if attempt == 0:
                    time.sleep(0.05)
        return None

    def _save_device_state(self):
        """Atomically write device state with exclusive file lock.

        Uses write-to-temp + os.replace for crash safety.
        Only sync_engine calls this (SINGLE-WRITER, Correction C).
        """
        if not self._device_state:
            return
        state_dir = os.path.dirname(_DEVICE_STATE_PATH) or "."
        os.makedirs(state_dir, exist_ok=True)
        tmp_path = None
        try:
            fd, tmp_path = tempfile.mkstemp(
                dir=state_dir, prefix=".device_state_", suffix=".tmp"
            )
            with os.fdopen(fd, "w") as f:
                if _HAS_FCNTL:
                    fcntl.flock(f, fcntl.LOCK_EX)
                try:
                    json.dump(self._device_state, f, indent=2)
                    f.flush()
                    os.fsync(f.fileno())
                finally:
                    if _HAS_FCNTL:
                        fcntl.flock(f, fcntl.LOCK_UN)
            os.replace(tmp_path, _DEVICE_STATE_PATH)
            tmp_path = None  # Successfully replaced, don't clean up
        except OSError as e:
            logger.error("Failed to save device state: %s", e)
        finally:
            # Clean up temp file on failure
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass

    def get_device_state(self):
        """Thread-safe read of current device state (for main.py / gui_app.py).

        Returns a deep COPY so consumers can't mutate internal state.
        READ-ONLY for external callers.
        """
        with self._state_lock:
            if self._device_state:
                return json.loads(json.dumps(self._device_state))
            return None

    def get_active_config(self):
        """Return the latest desired_config (thread-safe, no network call)."""
        with self._config_lock:
            return self._active_config.copy() if self._active_config else None

    # ── Authentication ────────────────────────────────────────────────

    def _get_headers(self):
        """Build auth headers: prefer device_token, fallback to JWT."""
        headers = {
            "apikey": self.supabase_key,
            "Content-Type": "application/json",
        }
        if self._device_state and self._device_state.get("device_token"):
            headers["X-Device-Token"] = str(self._device_state["device_token"])
            headers["Authorization"] = f"Bearer {self.supabase_key}"
        elif self._access_token:
            headers["Authorization"] = f"Bearer {self._access_token}"
        return headers

    def _authenticate(self):
        """Sign in with the Jetson service account to obtain a JWT."""
        if not self.email or not self.password:
            logger.warning("Sync email/password not configured, using anon key")
            self._access_token = self.supabase_key
            self._user_id = ""
            return

        url = f"{self.supabase_url}/auth/v1/token?grant_type=password"
        resp = requests.post(
            url,
            json={"email": self.email, "password": self.password},
            headers={
                "apikey": self.supabase_key,
                "Content-Type": "application/json",
            },
            timeout=15,
            verify=True,
        )
        resp.raise_for_status()
        data = resp.json()
        self._access_token = data["access_token"]
        self._user_id = data["user"]["id"]
        logger.info("Authenticated as %s (uid=%s)", self.email, self._user_id)

    # ── Remote config polling ─────────────────────────────────────────

    def _poll_device_config(self):
        """Poll Supabase for desired_config, user assignment, and status.

        Handles: assign, unassign, reassign, config updates.
        Skips silently if device is not provisioned.
        """
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = (
            f"{self.supabase_url}/rest/v1/devices"
            f"?device_token=eq.{token}"
            f"&select=desired_config,config_version,status,user_id"
        )

        try:
            resp = requests.get(url, headers=self._get_headers(), timeout=10, verify=True)
        except requests.RequestException as e:
            logger.warning("Config poll failed (network): %s", e)
            return

        if resp.status_code != 200 or not resp.json():
            logger.debug("Config poll: no data (HTTP %d)", resp.status_code)
            return

        device = resp.json()[0]

        # Unassign detection: user_id cleared or status='unassigned'
        if not device.get("user_id") or device["status"] == "unassigned":
            if self._device_state.get("user_id"):
                logger.warning(
                    "Device unassigned — pausing cloud sync "
                    "(local capture continues)"
                )
            with self._state_lock:
                self._device_state["user_id"] = None
                # Correction D: store desired_config in state for GUI
                self._device_state["desired_config"] = device.get("desired_config")
            self._save_device_state()
            return

        # Assign / reassign detection
        old_user = self._device_state.get("user_id")
        new_user = device["user_id"]
        if new_user != old_user:
            logger.info(
                "Device %s to user %s",
                "reassigned" if old_user else "assigned",
                new_user,
            )
            with self._state_lock:
                self._device_state["user_id"] = new_user
            self._save_device_state()

        # Config version check
        applied_ver = self._device_state.get("config_version_applied", -1)
        remote_ver = device.get("config_version", 0)
        desired = device.get("desired_config")

        if remote_ver > applied_ver and desired:
            logger.info(
                "Config update: v%d -> v%d: %s",
                applied_ver, remote_ver, json.dumps(desired),
            )
            with self._config_lock:
                self._active_config = desired
            # Correction D: store desired_config in state for GUI pending detection
            with self._state_lock:
                self._device_state["desired_config"] = desired
            self._save_device_state()
            self._report_config(desired, remote_ver)

    def _report_config(self, config, version):
        """ACK: report applied config back to Supabase."""
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/devices?device_token=eq.{token}"
        headers = self._get_headers()
        headers["Prefer"] = "return=minimal"

        try:
            resp = requests.patch(
                url,
                headers=headers,
                json={
                    "reported_config": config,
                    "status": "online",
                },
                timeout=10,
                verify=True,
            )
            if resp.status_code in (200, 204):
                with self._state_lock:
                    self._device_state["config_version_applied"] = version
                    # Correction D: store reported_config for GUI comparison
                    self._device_state["reported_config"] = config
                self._save_device_state()
                logger.info("Config v%d ACK sent", version)
            else:
                logger.warning(
                    "Config ACK failed: HTTP %d", resp.status_code
                )
        except requests.RequestException as e:
            logger.warning("Config ACK failed (network): %s", e)

    def _update_last_seen(self):
        """Heartbeat: update last_seen_at + status on Supabase."""
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/devices?device_token=eq.{token}"
        body = {"last_seen_at": datetime.now(timezone.utc).isoformat()}

        # Only set status=online if device has an assigned user
        if self._device_state.get("user_id"):
            body["status"] = "online"

        headers = self._get_headers()
        headers["Prefer"] = "return=minimal"

        try:
            requests.patch(url, headers=headers, json=body, timeout=10, verify=True)
        except requests.RequestException:
            pass  # Heartbeat is best-effort

    # ── Sync batch (LOCAL-FIRST) ──────────────────────────────────────

    def _sync_batch(self):
        """Sync unsynced predictions to Supabase.

        LOCAL-FIRST guarantee (Correction A):
          - If no user_id assigned: return early (skip POST only).
            Data stays safely in SQLite. The run() loop continues to
            poll for assignment on the next cycle.
          - When user_id becomes available: push ALL backlog including
            predictions recorded before assignment.
        """
        unsynced = self.db.get_unsynced(self.batch_size)
        if not unsynced:
            return

        # Determine user_id and device_id
        user_id = None
        device_id = None
        if self._device_state:
            user_id = self._device_state.get("user_id")
            device_id = self._device_state.get("device_id")
        elif self._user_id:
            # Legacy fallback: use JWT user_id
            user_id = self._user_id

        # Correction A: no user_id → skip POST only, loop keeps running
        if not user_id:
            logger.debug(
                "No user assigned — %d predictions queued locally",
                len(unsynced),
            )
            return  # Skip POST; run() loop continues for poll + heartbeat

        logger.info("Syncing %d predictions...", len(unsynced))

        headers = self._get_headers()
        headers["Prefer"] = "return=minimal"
        url = f"{self.supabase_url}/rest/v1/predictions"

        payload_list = []
        for pred in unsynced:
            leaf_type = pred["leaf_type"]
            model_cfg = self._models_config.get(leaf_type, {})
            model_version = model_cfg.get("version", "1.0.0")

            payload = {
                "user_id": user_id,
                "leaf_type": leaf_type,
                "predicted_class_index": pred["class_index"],
                "predicted_class_name": pred["class_name"],
                "confidence": pred["confidence"],
                "all_confidences": json.loads(pred["all_confidences"])
                if pred.get("all_confidences")
                else None,
                "inference_time_ms": pred.get("inference_time_ms"),
                "model_version": model_version,
                "source": "jetson",
                "created_at": pred["created_at"],
                "local_id": pred["id"],
            }
            if device_id:
                payload["device_id"] = device_id
            payload_list.append(payload)

        try:
            resp = requests.post(url, headers=headers, json=payload_list, timeout=30, verify=True)
            if resp.status_code in (200, 201):
                for pred in unsynced:
                    self.db.mark_synced(pred["id"])
            elif resp.status_code == 401:
                logger.warning("Auth expired, re-authenticating...")
                self._access_token = ""
            elif resp.status_code >= 500:
                logger.warning(
                    "Server error during sync: HTTP %d — will retry next cycle",
                    resp.status_code,
                )
                # Let outer run() loop handle backoff
                raise requests.exceptions.HTTPError(
                    f"Server error: {resp.status_code}"
                )
            else:
                logger.warning(
                    "Batch sync failed: HTTP %d %s",
                    resp.status_code,
                    resp.text[:200],
                )
        except requests.RequestException as e:
            logger.warning("Network error during batch sync: %s", e)

        stats = self.db.get_stats()
        logger.info(
            "Sync complete. Total: %d, Synced: %d, Pending: %d",
            stats["total_predictions"],
            stats["synced"],
            stats["unsynced"],
        )

    # ── Main loop ─────────────────────────────────────────────────────

    def run(self):
        """Main sync loop — runs as a daemon thread.

        Correction A: Loop NEVER stops. Even without user_id, it keeps
        running to poll for assignment. Only POST is skipped.
        Fix 1.6: Checks shutdown_event so main thread can drain gracefully.
        """
        base_interval = self.interval
        current_interval = base_interval
        max_interval = 3600
        while not self._shutdown_event.is_set():
            try:
                if self._is_configured:
                    # Auth: device_token preferred, JWT fallback
                    if not self._device_state and not self._access_token:
                        self._authenticate()

                    # Poll remote config + assignment (skip if not registered)
                    self._poll_device_config()

                    # Push predictions (skip POST if no user_id, data stays local)
                    self._sync_batch()

                    # Heartbeat (skip if not registered)
                    self._update_last_seen()
                else:
                    logger.debug("Supabase not configured, skipping sync")
                # Success — reset to base interval
                current_interval = base_interval
            except Exception as e:
                logger.error("Sync error: %s", e)
                # Reset token so next cycle re-authenticates
                self._access_token = ""
                # Exponential backoff on failure (cap at max_interval)
                current_interval = min(current_interval * 2, max_interval)
                logger.info(
                    "Backing off: next sync in %ds", current_interval
                )
            # Fix 1.6: Use Event.wait() instead of time.sleep() for
            # faster shutdown response (wakes immediately when set)
            self._shutdown_event.wait(timeout=current_interval)
