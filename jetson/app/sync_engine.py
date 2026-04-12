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
        self._session = requests.Session()
        # Retry adapter: handles transient connection/TLS failures
        from requests.adapters import HTTPAdapter
        from urllib3.util.retry import Retry
        retry = Retry(total=2, backoff_factor=1, status_forcelist=[502, 503, 504])
        self._session.mount("https://", HTTPAdapter(max_retries=retry))

        # JWT auth (legacy)
        self._access_token = ""
        self._user_id = ""

        # Device state: SINGLE-WRITER — only this class writes to file
        self._device_state = self._load_device_state()
        self._state_lock = threading.Lock()

        # Active config from remote (thread-safe read for main.py)
        # Initialize from persisted state so config survives restarts
        self._active_config = (
            self._device_state.get("desired_config")
            if self._device_state else None
        )
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
                except OSError:  # temp file already gone
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

    def stop(self):
        """Signal shutdown and close pending HTTP connections."""
        self._shutdown_event.set()
        self._session.close()

    # ── Authentication ────────────────────────────────────────────────

    def _get_headers(self):
        """Build Supabase gateway auth headers.

        X-Device-Token is no longer needed for RLS (we use RPC params),
        but apikey + Authorization are required by the Supabase gateway.
        """
        headers = {
            "apikey": self.supabase_key,
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.supabase_key}",
        }
        if self._access_token:
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
        resp = self._session.post(
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

        Uses RPC (device_poll_config) instead of direct REST query because
        Supabase gateway does not forward custom X-Device-Token headers to
        PostgREST, making header-based RLS policies ineffective.

        Handles: assign, unassign, reassign, config updates.
        Skips silently if device is not provisioned.
        """
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/rpc/device_poll_config"

        try:
            resp = self._session.post(
                url,
                headers=self._get_headers(),
                json={"p_device_token": token},
                timeout=(10, 30),
                verify=True,
            )
        except requests.RequestException as e:
            logger.warning("Config poll failed (network): %s", e)
            return

        if resp.status_code != 200:
            logger.debug("Config poll: HTTP %d", resp.status_code)
            return

        try:
            device = resp.json()
        except ValueError:
            logger.debug("Config poll: non-JSON response")
            return

        if not device:
            logger.debug("Config poll: device not found")
            return

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

        # ACK when: new version available OR first sync (applied=0, never ACK'd)
        needs_ack = (remote_ver > applied_ver) or (
            applied_ver == 0
            and desired
            and self._device_state.get("reported_config") is None
        )

        if needs_ack and desired:
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
        """ACK: report applied config back to Supabase via RPC."""
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/rpc/device_ack_config"

        try:
            resp = self._session.post(
                url,
                headers=self._get_headers(),
                json={
                    "p_device_token": token,
                    "p_reported_config": config,
                },
                timeout=10,
                verify=True,
            )
            if resp.status_code in (200, 204):
                with self._state_lock:
                    self._device_state["config_version_applied"] = version
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
        """Heartbeat: update last_seen_at + status on Supabase via RPC."""
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/rpc/device_heartbeat"

        try:
            self._session.post(
                url,
                headers=self._get_headers(),
                json={"p_device_token": token},
                timeout=10,
                verify=True,
            )
        except requests.RequestException:
            pass  # Heartbeat is best-effort

    # ── Image upload ──────────────────────────────────────────────────

    def _upload_image(self, local_path, user_id, local_id):
        """Upload a prediction image to Supabase Storage.

        Mirrors mobile app flow:
          - Bucket: prediction-images
          - Path: {user_id}/{timestamp}_{local_id}.jpg
          - Returns signed URL (365 days) or None on failure.
        """
        try:
            ts = int(time.time() * 1000)
            storage_path = f"{user_id}/{ts}_{local_id}.jpg"

            with open(local_path, "rb") as f:
                image_data = f.read()

            # Upload to Supabase Storage
            upload_url = (
                f"{self.supabase_url}/storage/v1/object/prediction-images/{storage_path}"
            )
            upload_headers = {
                "apikey": self.supabase_key,
                "Authorization": f"Bearer {self.supabase_key}",
                "Content-Type": "image/jpeg",
            }
            resp = self._session.post(
                upload_url, headers=upload_headers, data=image_data,
                timeout=(10, 30), verify=True,
            )
            if resp.status_code not in (200, 201):
                logger.warning(
                    "Image upload failed: HTTP %d %s",
                    resp.status_code, resp.text[:100],
                )
                return None

            # Create signed URL (365 days)
            sign_url = f"{self.supabase_url}/storage/v1/object/sign/prediction-images/{storage_path}"
            sign_headers = {
                "apikey": self.supabase_key,
                "Authorization": f"Bearer {self.supabase_key}",
                "Content-Type": "application/json",
            }
            sign_resp = self._session.post(
                sign_url, headers=sign_headers,
                json={"expiresIn": 365 * 24 * 3600},
                timeout=10, verify=True,
            )
            if sign_resp.status_code == 200:
                signed_data = sign_resp.json()
                # Supabase v1: signedURL, v2+: signedUrl
                signed_path = (
                    signed_data.get("signedURL")
                    or signed_data.get("signedUrl")
                    or ""
                )
                if signed_path:
                    # signedURL already includes /object/sign/ prefix
                    full_url = f"{self.supabase_url}/storage/v1{signed_path}"
                    logger.debug("Image uploaded: %s", storage_path)
                    return full_url

            logger.warning("Signed URL creation failed: HTTP %d", sign_resp.status_code)
            return None
        except (requests.RequestException, OSError) as e:
            logger.warning("Image upload error: %s", e)
            return None

    # ── Sync batch (LOCAL-FIRST) ──────────────────────────────────────

    def _sync_batch(self):
        """Sync unsynced predictions to Supabase.

        Flow per prediction:
          1. Upload image to Supabase Storage (if image_path exists)
          2. Get signed URL (365 days)
          3. Push prediction metadata + image_url via RPC
          4. Mark synced locally
          5. Delete local image file

        LOCAL-FIRST guarantee:
          - No user_id → skip POST, data stays in SQLite.
          - Image upload failure → prediction still syncs (without image).
          - RPC failure → retry next cycle, local image preserved.
        """
        unsynced = self.db.get_unsynced(self.batch_size)
        if not unsynced:
            return

        # Check user assignment — skip push if no user assigned
        user_id = None
        if self._device_state:
            user_id = self._device_state.get("user_id")
        elif self._user_id:
            user_id = self._user_id

        if not user_id:
            logger.debug(
                "No user assigned — %d predictions queued locally",
                len(unsynced),
            )
            return

        logger.info("Syncing %d predictions...", len(unsynced))

        headers = self._get_headers()
        url = f"{self.supabase_url}/rest/v1/rpc/device_push_predictions"
        token = self._device_state["device_token"] if self._device_state else None

        payload_list = []
        for pred in unsynced:
            leaf_type = pred["leaf_type"]
            model_cfg = self._models_config.get(leaf_type, {})
            model_version = model_cfg.get("version", "1.0.0")

            # Upload image to Supabase Storage (skip if already uploaded)
            image_url = pred.get("uploaded_image_url")
            local_path = pred.get("image_path")
            if not image_url and local_path and os.path.isfile(local_path):
                image_url = self._upload_image(local_path, user_id, pred["id"])
                if image_url:
                    # Persist URL so retries don't re-upload
                    self.db.set_uploaded_image_url(pred["id"], image_url)

            payload = {
                "leaf_type": leaf_type,
                "predicted_class_index": pred["class_index"],
                "predicted_class_name": pred["class_name"],
                "confidence": pred["confidence"],
                "all_confidences": json.loads(pred["all_confidences"])
                if pred.get("all_confidences")
                else None,
                "inference_time_ms": pred.get("inference_time_ms"),
                "model_version": model_version,
                "created_at": pred["created_at"],
                "local_id": pred["id"],
                "image_url": image_url,
            }
            payload_list.append(payload)

        try:
            resp = self._session.post(
                url,
                headers=headers,
                json={
                    "p_device_token": token,
                    "p_predictions": payload_list,
                },
                timeout=30,
                verify=True,
            )
            if resp.status_code in (200, 201):
                for pred in unsynced:
                    self.db.mark_synced(pred["id"])
                # Delete ALL local images after successful sync
                # (covers both fresh uploads and retry-path images)
                for pred in unsynced:
                    local_path = pred.get("image_path")
                    if local_path:
                        try:
                            os.unlink(local_path)
                        except OSError:
                            pass
            elif resp.status_code == 401:
                logger.warning("Auth expired, re-authenticating...")
                self._access_token = ""
            elif resp.status_code >= 500:
                logger.warning(
                    "Server error during sync: HTTP %d — will retry next cycle",
                    resp.status_code,
                )
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
