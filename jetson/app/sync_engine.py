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

    def __init__(self, config, db, models_config=None, shutdown_event=None,
                 inference_pool=None, config_path=None):
        self.supabase_url = config.get("supabase_url", "")
        self.supabase_key = config.get("supabase_key", "")
        self.email = config.get("email", "")
        self.password = config.get("password", "")
        self.batch_size = config.get("batch_size", 50)
        self.interval = config.get("interval_seconds", 300)
        self.db = db
        self._models_config = models_config or {}
        self._shutdown_event = shutdown_event or threading.Event()
        self._inference_pool = inference_pool  # For hot-swap
        self._config_path = config_path        # For persisting model updates
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

        # DVC lock: serialize validation to prevent concurrent DVC pulls
        self._dvc_lock = threading.Lock()

        # Engine build status per leaf_type: 'ready' | 'building' | 'error'
        self._engine_status = {}
        # Applied model versions (track what's actually loaded)
        self._applied_model_versions = {}
        for lt, cfg in self._models_config.items():
            self._applied_model_versions[lt] = cfg.get("version", "1.0.0")
            self._engine_status[lt] = "ready"

        if self._device_state:
            logger.info(
                "Device state loaded: device_id=%s, hw_id=%s",
                self._device_state.get("device_id"),
                self._device_state.get("hw_id", "")[:12],
            )

    @property
    def _is_configured(self):
        return bool(self.supabase_url and self.supabase_key)

    def get_model_version(self, leaf_type):
        """Get the currently applied model version for a leaf_type."""
        return self._applied_model_versions.get(leaf_type, "1.0.0")

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

            # Check for model version changes and trigger builds
            self._check_model_versions(desired)

            self._report_config(desired, remote_ver)

    def _report_config(self, config, version):
        """ACK: report applied config back to Supabase via RPC.

        Includes engine_status in reported_config so dashboard can show
        build progress per model.
        """
        if not self._device_state:
            return

        token = self._device_state["device_token"]
        url = f"{self.supabase_url}/rest/v1/rpc/device_ack_config"

        # Merge engine status into reported config
        reported = dict(config) if config else {}
        if self._engine_status:
            reported["engine_status"] = dict(self._engine_status)
        # Include applied model versions
        if self._applied_model_versions:
            reported["applied_model_versions"] = dict(self._applied_model_versions)

        try:
            resp = self._session.post(
                url,
                headers=self._get_headers(),
                json={
                    "p_device_token": token,
                    "p_reported_config": reported,
                },
                timeout=10,
                verify=True,
            )
            if resp.status_code in (200, 204):
                with self._state_lock:
                    self._device_state["config_version_applied"] = version
                    self._device_state["reported_config"] = reported
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

    # ── Engine management (auto-build/download) ──────────────────────

    def _check_model_versions(self, desired_config):
        """Check if model_versions in desired_config differ from applied.

        If a version changed, trigger engine build/download in background.
        """
        desired_mv = desired_config.get("model_versions", {})
        if not desired_mv:
            return

        for leaf_type, desired_ver in desired_mv.items():
            current_ver = self._applied_model_versions.get(leaf_type)
            if current_ver == desired_ver:
                continue
            if self._engine_status.get(leaf_type) == "building":
                continue  # Already building

            logger.info(
                "Model version change: %s %s -> %s, triggering engine build",
                leaf_type, current_ver, desired_ver,
            )
            self._engine_status[leaf_type] = "building"
            # Run build in background thread to avoid blocking sync loop
            t = threading.Thread(
                target=self._build_engine,
                args=(leaf_type, desired_ver),
                daemon=True,
                name=f"engine-build-{leaf_type}",
            )
            t.start()

    def _build_engine(self, leaf_type, version):
        """Download ONNX and build TensorRT engine for a specific version.

        Steps:
          1. Query Supabase for ONNX URL (get_latest_onnx_url or by version)
          2. Check if cached engine exists (get_engine_for_hardware)
          3. Download cached or build from ONNX
          4. Hot-swap inference engine
          5. Update local config
          6. Delete old engine file
        """
        try:
            models_dir = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "models"
            )
            os.makedirs(models_dir, exist_ok=True)

            # Detect hardware tag
            hw_tag = self._get_hardware_tag()

            # Step 1: Check for cached engine
            engine_info = self._supabase_rpc("get_engine_for_hardware", {
                "p_leaf_type": leaf_type,
                "p_version": version,
                "p_hardware_tag": hw_tag,
            })

            new_engine_path = os.path.join(
                models_dir, f"{leaf_type}_student_v{version}.engine"
            )

            if engine_info and len(engine_info) > 0 and engine_info[0].get("engine_url"):
                # Download cached engine
                logger.info("Downloading cached engine: %s v%s (%s)", leaf_type, version, hw_tag)
                engine_url = engine_info[0]["engine_url"]
                expected_sha = engine_info[0].get("engine_sha256", "")
                self._download_file(engine_url, new_engine_path)

                # Verify SHA256
                if expected_sha:
                    actual_sha = self._sha256_file(new_engine_path)
                    if actual_sha != expected_sha:
                        logger.error("Engine SHA256 mismatch for %s v%s", leaf_type, version)
                        self._engine_status[leaf_type] = "error"
                        return

                # Check if benchmark already exists — skip validation if so
                has_benchmark = bool(engine_info[0].get("benchmark_json"))
                needs_validation = not has_benchmark
            else:
                # Step 2: Get ONNX URL for this specific version
                # First try exact version match via REST query
                onnx_url = self._get_onnx_url_for_version(leaf_type, version)
                actual_onnx_version = version  # Track which version we actually download

                if not onnx_url:
                    # Fallback: get_latest_onnx_url RPC — WARNING: may return different version!
                    # This ensures device has SOME model, but version must be updated accordingly
                    onnx_info = self._supabase_rpc("get_latest_onnx_url", {
                        "p_leaf_type": leaf_type,
                    })
                    if onnx_info and len(onnx_info) > 0:
                        onnx_url = onnx_info[0].get("onnx_url")
                        fallback_version = onnx_info[0].get("version")
                        if fallback_version and fallback_version != version:
                            logger.warning(
                                "Requested %s v%s not found, falling back to v%s (active)",
                                leaf_type, version, fallback_version
                            )
                            actual_onnx_version = fallback_version
                            # Update the engine path to match actual version
                            new_engine_path = os.path.join(
                                models_dir, f"{leaf_type}_student_v{actual_onnx_version}.engine"
                            )

                if not onnx_url:
                    logger.error("No ONNX URL for %s v%s", leaf_type, version)
                    self._engine_status[leaf_type] = "error"
                    return

                # Use actual_onnx_version for all subsequent operations
                version = actual_onnx_version

                # Step 3: Download ONNX and build engine
                from engine_builder import build_engine

                with tempfile.TemporaryDirectory() as tmpdir:
                    onnx_path = os.path.join(tmpdir, f"{leaf_type}_student.onnx")
                    logger.info("Downloading ONNX: %s v%s", leaf_type, version)
                    self._download_file(onnx_url, onnx_path)

                    logger.info("Building TensorRT engine: %s v%s (this may take 10-30 min)", leaf_type, version)
                    try:
                        build_engine(onnx_path, new_engine_path, timeout=1800)
                    except FileNotFoundError as e:
                        logger.error("%s", e)
                        self._engine_status[leaf_type] = "error"
                        return
                    except RuntimeError as e:
                        logger.error("%s", e)
                        self._engine_status[leaf_type] = "error"
                        return

                # Upload built engine to cache for other devices
                engine_sha = self._sha256_file(new_engine_path)
                self._upload_engine_cache(leaf_type, version, hw_tag, new_engine_path, engine_sha)

                needs_validation = True  # New engine always needs benchmark

            # Step 4: Hot-swap inference engine
            logger.info("Hot-swapping engine: %s v%s", leaf_type, version)
            old_engine_path = self._models_config.get(leaf_type, {}).get("engine_path", "")

            # Get model metadata from registry for class info
            model_meta = self._get_model_metadata(leaf_type, version)

            if self._inference_pool:
                self._inference_pool.hot_swap(leaf_type, new_engine_path, model_meta)

            # Step 5: Update local config
            if leaf_type not in self._models_config:
                self._models_config[leaf_type] = {}
            self._models_config[leaf_type]["engine_path"] = new_engine_path
            self._models_config[leaf_type]["version"] = version
            if model_meta:
                self._models_config[leaf_type]["num_classes"] = model_meta.get("num_classes")
                self._models_config[leaf_type]["class_labels"] = model_meta.get("class_labels")
                self._models_config[leaf_type]["sha256_checksum"] = self._sha256_file(new_engine_path)
            self._persist_config()

            # Step 6: Delete old engine
            if old_engine_path and os.path.isfile(old_engine_path) and old_engine_path != new_engine_path:
                try:
                    os.unlink(old_engine_path)
                    logger.info("Deleted old engine: %s", old_engine_path)
                except OSError as e:
                    logger.debug("Could not delete old engine %s: %s", old_engine_path, e)

            self._applied_model_versions[leaf_type] = version
            self._engine_status[leaf_type] = "ready"
            logger.info("Engine update complete: %s v%s", leaf_type, version)

            # Step 7: On-device validation (non-blocking, non-fatal)
            if needs_validation:
                self._run_engine_validation(leaf_type, version, hw_tag, new_engine_path)

            # Re-report config so dashboard sees updated engine_status
            self._re_report_engine_status()

        except Exception as e:
            logger.error("Engine build failed for %s v%s: %s", leaf_type, version, e)
            self._engine_status[leaf_type] = "error"
            self._re_report_engine_status()

    def _run_engine_validation(self, leaf_type, version, hw_tag, engine_path):
        """Run on-device TensorRT validation: DVC pull → eval → upload → cleanup.

        Non-fatal: if validation fails, the engine is still usable.
        Uses _dvc_lock to serialize DVC pulls (avoid lock conflicts).
        """
        # Acquire DVC lock to prevent concurrent pulls (DVC uses file locks)
        with self._dvc_lock:
            self._run_engine_validation_locked(leaf_type, version, hw_tag, engine_path)

    def _run_engine_validation_locked(self, leaf_type, version, hw_tag, engine_path):
        """Internal validation logic (must be called with _dvc_lock held).

        Runs validation in a subprocess to avoid CUDA context conflicts
        with the main inference worker (which holds the primary CUDA context).
        """
        try:
            # Load full config from file (SyncEngine only stores sync subsection)
            if not self._config_path or not os.path.isfile(self._config_path):
                logger.info("Config file not available — skipping engine validation")
                return

            logger.info("Starting engine validation: %s v%s (%s)", leaf_type, version, hw_tag)

            # Run validation in subprocess to avoid CUDA context conflicts
            import subprocess
            scripts_dir = os.path.join(
                os.path.dirname(os.path.abspath(__file__)), "..", "scripts"
            )
            validate_script = os.path.join(scripts_dir, "validate_engine.py")

            if not os.path.isfile(validate_script):
                logger.warning("validate_engine.py not found — skipping validation")
                return

            # Pass Supabase credentials via environment for benchmark upload
            env = os.environ.copy()
            env["SUPABASE_URL"] = self.supabase_url
            env["SUPABASE_KEY"] = self.supabase_key

            # Use repo root as cwd so DVC can find dvc/ directory
            # Config is at /opt/agrikd/config/config.json, repo root is /opt/agrikd
            config_abs = os.path.abspath(self._config_path)
            repo_root = os.path.dirname(os.path.dirname(config_abs))

            result = subprocess.run(
                [
                    "python3", validate_script,
                    "--config", config_abs,
                    "--leaf-type", leaf_type,
                    "--engine-path", os.path.abspath(engine_path),
                    "--version", version,
                    "--hw-tag", hw_tag,
                ],
                capture_output=True,
                text=True,
                timeout=1800,  # 30 min timeout
                env=env,
                cwd=repo_root,
            )

            if result.returncode == 0:
                # Parse last line for summary
                lines = result.stdout.strip().split("\n")
                for line in reversed(lines):
                    if "Validation done" in line or "acc=" in line:
                        logger.info(line)
                        break
                else:
                    logger.info("Validation completed: %s v%s", leaf_type, version)
            else:
                logger.warning(
                    "Validation subprocess failed for %s: %s",
                    leaf_type, result.stderr[-500:] if result.stderr else "no error output"
                )

        except subprocess.TimeoutExpired:
            logger.error("Validation timeout for %s v%s", leaf_type, version)
        except Exception as e:
            logger.error("Engine validation failed (non-fatal) for %s: %s", leaf_type, e)

    def _fetch_and_save_gcs_key(self, config):
        """Fetch GCS key from Supabase system_secrets and save locally.

        Returns the local file path if successful, None otherwise.
        """
        device_state = self._device_state or {}
        device_token = device_state.get("device_token")
        if not device_token:
            return None

        try:
            result = self._supabase_rpc("get_system_secret", {
                "p_device_token": device_token,
                "p_key": "gcs_readonly_key",
            })
            # RPC returns the value directly (TEXT), not an array
            gcs_json = result if isinstance(result, str) else None
            if not gcs_json:
                return None

            base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            gcs_dir = os.path.join(base_dir, "config", "secrets")
            os.makedirs(gcs_dir, exist_ok=True)
            gcs_path = os.path.join(gcs_dir, "gcs-readonly.json")

            with open(gcs_path, "w") as f:
                f.write(gcs_json)
            try:
                os.chmod(gcs_path, 0o600)
            except OSError:
                logger.debug("Could not set permissions on %s (non-fatal)", gcs_path)

            # Update config.json with GCS path
            config["gcs"] = {"credentials_path": gcs_path}
            if self._config_path:
                with self._config_lock:
                    with open(self._config_path, "w") as f:
                        json.dump(config, f, indent=4)

            logger.info("GCS credentials fetched from Supabase and saved to %s", gcs_path)
            return gcs_path

        except Exception as e:
            logger.debug("Could not fetch GCS key from Supabase: %s", e)
            return None

    def _re_report_engine_status(self):
        """Re-send reported_config with current engine_status to dashboard."""
        if not self._device_state:
            return
        applied_ver = self._device_state.get("config_version_applied", -1)
        desired = self._device_state.get("desired_config")
        if desired and applied_ver >= 0:
            self._report_config(desired, applied_ver)

    def _supabase_rpc(self, fn_name, params):
        """Call Supabase RPC and return JSON result."""
        try:
            resp = self._session.post(
                f"{self.supabase_url}/rest/v1/rpc/{fn_name}",
                headers=self._get_headers(),
                json=params, timeout=15, verify=True,
            )
            if resp.status_code == 200:
                return resp.json()
            logger.warning("RPC %s failed: HTTP %d", fn_name, resp.status_code)
        except requests.RequestException as e:
            logger.warning("RPC %s error: %s", fn_name, e)
        return None

    def _validate_download_url(self, url):
        """Validate download URL points to configured Supabase host (SSRF prevention)."""
        from urllib.parse import urlparse
        try:
            parsed = urlparse(url)
            allowed_host = urlparse(self.supabase_url).hostname
        except Exception as exc:
            raise ValueError(f"Malformed URL: {url[:80]}") from exc
        if parsed.scheme != "https":
            raise ValueError(f"Only HTTPS download URLs are allowed: {url[:80]}")
        if parsed.hostname != allowed_host:
            raise ValueError(
                f"Download URL host '{parsed.hostname}' does not match "
                f"configured Supabase host '{allowed_host}'"
            )

    def _download_file(self, url, dest_path):
        """Download file from Supabase Storage with atomic write.

        Downloads to a temp file first, then renames on success to
        prevent partial/corrupted files if interrupted (T2-02).
        """
        self._validate_download_url(url)
        tmp_path = dest_path + ".tmp"
        try:
            resp = self._session.get(
                url,
                headers={
                    "apikey": self.supabase_key,
                    "Authorization": f"Bearer {self.supabase_key}",
                },
                timeout=(10, 300), stream=True, verify=True,
            )
            resp.raise_for_status()
            with open(tmp_path, "wb") as f:
                for chunk in resp.iter_content(chunk_size=8192):
                    f.write(chunk)
            os.replace(tmp_path, dest_path)
        except BaseException:
            # Clean up partial temp file on any failure
            try:
                os.unlink(tmp_path)
            except OSError:
                logger.debug("Temp file %s already removed", tmp_path)
            raise

    def _sha256_file(self, path):
        """Compute SHA-256 hash of a file."""
        import hashlib
        sha = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                sha.update(chunk)
        return sha.hexdigest()

    def _get_hardware_tag(self):
        """Detect device hardware tag for engine cache matching.

        Format: {hw_model}_trt{trt_version}
        Example: jetson-orin-nx-engineering-reference_trt10.3.0.30

        Must match the tag produced by setup_jetson.sh so engines are
        downloaded from / uploaded to the same Storage path.
        """
        import subprocess
        hw_model = "unknown"
        trt_ver = "unknown"
        try:
            with open("/proc/device-tree/model", "r") as f:
                hw_model = f.read().strip().rstrip("\x00")
            hw_model = (hw_model.lower()
                        .replace("nvidia ", "")
                        .replace(" developer kit", "")
                        .replace(" ", "-"))
        except Exception:
            logger.debug("Could not read /proc/device-tree/model")
        try:
            result = subprocess.run(
                ["dpkg", "-l", "tensorrt"],
                capture_output=True, text=True, timeout=10,
            )
            for line in result.stdout.splitlines():
                if line.startswith("ii"):
                    trt_ver = line.split()[2].split("-")[0]
                    break
        except Exception:
            logger.debug("Could not detect TensorRT version via dpkg")
        return f"{hw_model}_trt{trt_ver}"

    def _upload_engine_cache(self, leaf_type, version, hw_tag, engine_path, engine_sha):
        """Upload built engine to Supabase Storage for other devices to reuse.

        Uses curl subprocess instead of Python requests to avoid SSL issues
        with large file uploads on Jetson (requests + urllib3 has problems
        with HTTP/2 and large streaming uploads).
        """
        try:
            storage_path = f"engines/{leaf_type}/{version}/{hw_tag}.engine"
            upload_url = f"{self.supabase_url}/storage/v1/object/models/{storage_path}"

            # Use curl for reliable large file uploads
            import subprocess
            result = subprocess.run(
                [
                    "curl", "-s", "-S", "-f",
                    "-X", "POST", upload_url,
                    "-H", f"apikey: {self.supabase_key}",
                    "-H", f"Authorization: Bearer {self.supabase_key}",
                    "-H", "Content-Type: application/octet-stream",
                    "-H", "x-upsert: true",
                    "--data-binary", f"@{engine_path}",
                    "--max-time", "300",
                    "--retry", "3",
                    "--retry-delay", "5",
                ],
                capture_output=True,
                text=True,
                timeout=360,
            )

            if result.returncode == 0:
                # Register in model_engines table (upsert for re-builds)
                engine_url = f"{self.supabase_url}/storage/v1/object/public/models/{storage_path}"
                device_id = self._device_state.get("device_id") if self._device_state else None
                self._session.post(
                    f"{self.supabase_url}/rest/v1/model_engines",
                    headers={**self._get_headers(), "Prefer": "return=minimal,resolution=merge-duplicates"},
                    json={
                        "leaf_type": leaf_type,
                        "version": version,
                        "hardware_tag": hw_tag,
                        "engine_url": engine_url,
                        "engine_sha256": engine_sha,
                        "created_by_device": device_id,
                    },
                    timeout=10, verify=True,
                )
                logger.info("Engine cached: %s v%s %s", leaf_type, version, hw_tag)
            else:
                logger.warning("Engine upload failed (curl): %s", result.stderr[:500])
        except Exception as e:
            logger.warning("Engine cache upload failed (non-fatal): %s", e)

    def _get_model_metadata(self, leaf_type, version):
        """Fetch model metadata (num_classes, class_labels) from model_registry."""
        try:
            resp = self._session.get(
                f"{self.supabase_url}/rest/v1/model_registry"
                f"?leaf_type=eq.{leaf_type}&version=eq.{version}&select=num_classes,class_labels",
                headers=self._get_headers(),
                timeout=10, verify=True,
            )
            if resp.status_code == 200:
                data = resp.json()
                if data and len(data) > 0:
                    return data[0]
        except requests.RequestException as e:
            logger.debug("Failed to fetch model metadata for %s v%s: %s", leaf_type, version, e)
        return None

    def _get_onnx_url_for_version(self, leaf_type, version):
        """Fetch ONNX URL for a specific leaf_type + version from model_registry."""
        try:
            resp = self._session.get(
                f"{self.supabase_url}/rest/v1/model_registry"
                f"?leaf_type=eq.{leaf_type}&version=eq.{version}&select=onnx_url",
                headers=self._get_headers(),
                timeout=10, verify=True,
            )
            if resp.status_code == 200:
                data = resp.json()
                if data and len(data) > 0:
                    return data[0].get("onnx_url")
        except requests.RequestException as e:
            logger.debug("Failed to fetch ONNX URL for %s v%s: %s", leaf_type, version, e)
        return None

    def _persist_config(self):
        """Write updated models config back to config.json.

        Protected by _config_lock to prevent concurrent engine build threads
        from corrupting the file via read-modify-write races.
        """
        if not self._config_path:
            return
        with self._config_lock:
            try:
                with open(self._config_path, "r") as f:
                    full_config = json.load(f)
                full_config["models"] = self._models_config
                with open(self._config_path, "w") as f:
                    json.dump(full_config, f, indent=4)
                logger.debug("Config persisted to %s", self._config_path)
            except (OSError, json.JSONDecodeError) as e:
                logger.warning("Failed to persist config: %s", e)

    # ── Image upload ──────────────────────────────────────────────────

    def _upload_image(self, local_path, user_id, local_id):
        """Upload a prediction image to Supabase Storage.

        Mirrors mobile app flow:
          - Bucket: prediction-images
          - Path: {user_id}/{timestamp}_{local_id}.jpg
          - Returns storage path 'prediction-images/{path}' or None on failure.
            The admin dashboard re-signs on demand, so a permanent path reference
            is cleaner and never expires.
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

            logger.debug("Image uploaded: %s", storage_path)
            # Return storage path — admin dashboard re-signs on demand
            return f"prediction-images/{storage_path}"
        except (requests.RequestException, OSError) as e:
            logger.warning("Image upload error: %s", e)
            return None

    # ── Sync batch (LOCAL-FIRST) ──────────────────────────────────────

    def _sync_batch(self):
        """Sync unsynced predictions to Supabase.

        Flow per prediction:
          1. Upload image to Supabase Storage (if image_path exists)
          2. Store permanent storage path in image_url (admin dashboard re-signs on demand)
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

        # Track which predictions had successful image uploads
        uploaded_pred_ids = set()

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
                    self.db.set_uploaded_image_url(pred["id"], image_url)

            if image_url:
                uploaded_pred_ids.add(pred["id"])

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
                # Only delete local images that were successfully uploaded
                for pred in unsynced:
                    if pred["id"] in uploaded_pred_ids:
                        local_path = pred.get("image_path")
                        if local_path:
                            try:
                                os.unlink(local_path)
                            except OSError as e:
                                logger.debug("Could not remove local image %s: %s", local_path, e)
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
                # Client error (4xx except 401) — increment retry count
                # so persistently failing predictions are eventually skipped
                for pred in unsynced:
                    self.db.increment_retry_count(pred["id"])
                logger.warning(
                    "Batch sync failed: HTTP %d %s (retry counts incremented)",
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

    def _retry_image_uploads(self):
        """Retry uploading images for predictions that synced without image_url.

        This handles the case where image upload failed (e.g. RLS policy error)
        but the prediction metadata was successfully pushed.
        """
        user_id = None
        if self._device_state:
            user_id = self._device_state.get("user_id")
        if not user_id:
            return

        pending = self.db.get_pending_image_uploads(limit=10)
        if not pending:
            return

        logger.info("Retrying image upload for %d predictions...", len(pending))

        headers = self._get_headers()
        token = self._device_state["device_token"] if self._device_state else None

        for pred in pending:
            local_path = pred.get("image_path")
            if not local_path or not os.path.isfile(local_path):
                # File gone — mark as handled so we don't retry forever
                self.db.set_uploaded_image_url(pred["id"], "")
                continue

            image_url = self._upload_image(local_path, user_id, pred["id"])
            if image_url:
                self.db.set_uploaded_image_url(pred["id"], image_url)
                # Update Supabase prediction with image_url via RPC
                try:
                    self._session.post(
                        f"{self.supabase_url}/rest/v1/rpc/device_update_prediction_image",
                        headers=headers,
                        json={
                            "p_device_token": token,
                            "p_local_id": pred["id"],
                            "p_image_url": image_url,
                        },
                        timeout=10, verify=True,
                    )
                except requests.RequestException as e:
                    logger.debug("Best-effort image URL update failed: %s", e)
                # Delete local image
                try:
                    os.unlink(local_path)
                except OSError as e:
                    logger.debug("Could not remove local image %s: %s", local_path, e)
                logger.debug("Retry upload OK: pred %d", pred["id"])

    # ── Main loop ─────────────────────────────────────────────────────

    def run(self):
        """Main sync loop — runs as a daemon thread.

        Correction A: Loop NEVER stops. Even without user_id, it keeps
        running to poll for assignment. Only POST is skipped.
        Fix 1.6: Checks shutdown_event so main thread can drain gracefully.
        """
        # Pre-check: if desired_config has model_versions, verify engines
        # match and trigger builds immediately (don't wait for first poll)
        if self._active_config:
            desired_mv = self._active_config.get("model_versions", {})
            if desired_mv:
                logger.info("Startup engine check: verifying assigned model versions")
                self._check_model_versions(self._active_config)

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

                    # Retry image uploads for previously synced predictions
                    self._retry_image_uploads()

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
