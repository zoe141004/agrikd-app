"""Sync engine for pushing predictions to Supabase."""

import json
import logging
import time

import requests


logger = logging.getLogger("sync")


class SyncEngine:
    """Background sync of predictions to Supabase via HTTP POST.

    Authenticates as a dedicated Jetson service account so that
    predictions pass the RLS policy ``auth.uid() = user_id``.
    """

    def __init__(self, config, db, models_config=None):
        self.supabase_url = config.get("supabase_url", "")
        self.supabase_key = config.get("supabase_key", "")
        self.email = config.get("email", "")
        self.password = config.get("password", "")
        self.batch_size = config.get("batch_size", 50)
        self.interval = config.get("interval_seconds", 300)
        self.db = db
        self._models_config = models_config or {}

        # Populated by _authenticate()
        self._access_token = ""
        self._user_id = ""

    @property
    def _is_configured(self):
        return bool(self.supabase_url and self.supabase_key)

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
        )
        resp.raise_for_status()
        data = resp.json()
        self._access_token = data["access_token"]
        self._user_id = data["user"]["id"]
        logger.info("Authenticated as %s (uid=%s)", self.email, self._user_id)

    def run(self):
        """Main sync loop — runs as a daemon thread."""
        while True:
            try:
                if self._is_configured:
                    if not self._access_token:
                        self._authenticate()
                    self._sync_batch()
                else:
                    logger.debug("Supabase not configured, skipping sync")
            except Exception as e:
                logger.error("Sync error: %s", e)
                # Reset token so next cycle re-authenticates
                self._access_token = ""
            time.sleep(self.interval)

    def _sync_batch(self):
        """Sync a batch of unsynced predictions via single POST."""
        unsynced = self.db.get_unsynced(self.batch_size)
        if not unsynced:
            return

        logger.info("Syncing %d predictions...", len(unsynced))

        headers = {
            "apikey": self.supabase_key,
            "Authorization": f"Bearer {self._access_token}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        }

        url = f"{self.supabase_url}/rest/v1/predictions"

        # M9: Build a single payload array for batch POST
        payload_list = []
        for pred in unsynced:
            # H5: Read version from models config, fallback to "1.0.0"
            leaf_type = pred["leaf_type"]
            model_cfg = self._models_config.get(leaf_type, {})
            model_version = model_cfg.get("version", "1.0.0")

            payload_list.append({
                "user_id": self._user_id or None,
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
            })

        try:
            resp = requests.post(url, headers=headers, json=payload_list, timeout=30)
            if resp.status_code in (200, 201):
                for pred in unsynced:
                    self.db.mark_synced(pred["id"])
            elif resp.status_code == 401:
                logger.warning("Auth expired, re-authenticating...")
                self._authenticate()
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
