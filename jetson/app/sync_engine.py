"""Sync engine for pushing predictions to Supabase."""

import json
import logging
import time

import requests


logger = logging.getLogger("sync")


class SyncEngine:
    """Background sync of predictions to Supabase via HTTP POST."""

    def __init__(self, config, db):
        self.supabase_url = config.get("supabase_url", "")
        self.supabase_key = config.get("supabase_key", "")
        self.batch_size = config.get("batch_size", 50)
        self.interval = config.get("interval_seconds", 300)
        self.db = db

    def run(self):
        """Main sync loop — runs as a daemon thread."""
        while True:
            try:
                if self.supabase_url and self.supabase_key:
                    self._sync_batch()
                else:
                    logger.debug("Supabase not configured, skipping sync")
            except Exception as e:
                logger.error("Sync error: %s", e)
            time.sleep(self.interval)

    def _sync_batch(self):
        """Sync a batch of unsynced predictions."""
        unsynced = self.db.get_unsynced(self.batch_size)
        if not unsynced:
            return

        logger.info("Syncing %d predictions...", len(unsynced))

        headers = {
            "apikey": self.supabase_key,
            "Authorization": f"Bearer {self.supabase_key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        }

        url = f"{self.supabase_url}/rest/v1/predictions"

        for pred in unsynced:
            payload = {
                "leaf_type": pred["leaf_type"],
                "predicted_class_index": pred["class_index"],
                "predicted_class_name": pred["class_name"],
                "confidence": pred["confidence"],
                "all_confidences": json.loads(pred["all_confidences"])
                if pred.get("all_confidences")
                else None,
                "inference_time_ms": pred.get("inference_time_ms"),
                "model_version": "1.0.0",
                "created_at": pred["created_at"],
                "local_id": pred["id"],
            }

            try:
                resp = requests.post(url, headers=headers, json=payload, timeout=10)
                if resp.status_code in (200, 201):
                    self.db.mark_synced(pred["id"])
                else:
                    logger.warning(
                        "Sync failed for id=%d: HTTP %d", pred["id"], resp.status_code
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
