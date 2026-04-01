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

    def __init__(self, config, db):
        self.supabase_url = config.get("supabase_url", "")
        self.supabase_key = config.get("supabase_key", "")
        self.email = config.get("email", "")
        self.password = config.get("password", "")
        self.batch_size = config.get("batch_size", 50)
        self.interval = config.get("interval_seconds", 300)
        self.db = db

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
        """Sync a batch of unsynced predictions."""
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

        for pred in unsynced:
            payload = {
                "user_id": self._user_id or None,
                "leaf_type": pred["leaf_type"],
                "predicted_class_index": pred["class_index"],
                "predicted_class_name": pred["class_name"],
                "confidence": pred["confidence"],
                "all_confidences": json.loads(pred["all_confidences"])
                if pred.get("all_confidences")
                else None,
                "inference_time_ms": pred.get("inference_time_ms"),
                "model_version": "1.0.0",
                "source": "jetson",
                "created_at": pred["created_at"],
                "local_id": pred["id"],
            }

            try:
                resp = requests.post(url, headers=headers, json=payload, timeout=10)
                if resp.status_code in (200, 201):
                    self.db.mark_synced(pred["id"])
                elif resp.status_code == 401:
                    logger.warning("Auth expired, re-authenticating...")
                    self._authenticate()
                    break  # Retry batch on next cycle
                else:
                    logger.warning(
                        "Sync failed for id=%d: HTTP %d %s",
                        pred["id"],
                        resp.status_code,
                        resp.text[:200],
                    )
            except requests.RequestException as e:
                logger.warning("Network error syncing id=%d: %s", pred["id"], e)
                break  # Stop batch on network error

        stats = self.db.get_stats()
        logger.info(
            "Sync complete. Total: %d, Synced: %d, Pending: %d",
            stats["total_predictions"],
            stats["synced"],
            stats["unsynced"],
        )
