"""SQLite database for Jetson edge predictions (WAL mode, thread-safe)."""

import json
import logging
import os
import shutil
import sqlite3
import threading

logger = logging.getLogger("database")

# Minimum free disk space (bytes) required before writing
_MIN_DISK_BYTES = 50 * 1024 * 1024  # 50 MB


class JetsonDatabase:
    """Lightweight SQLite store for edge predictions.

    Thread-safety: A single threading.Lock serializes all operations on
    the shared sqlite3.Connection.  WAL mode allows the OS-level reader/
    writer concurrency; the Python lock prevents concurrent cursor use
    on the same connection (which sqlite3 does not guarantee even with
    ``check_same_thread=False``).
    """

    def __init__(self, db_path):
        os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
        self.db_path = db_path
        self._lock = threading.Lock()
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self._create_tables()

    def _create_tables(self):
        with self._lock:
            self.conn.executescript("""
                CREATE TABLE IF NOT EXISTS predictions (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    leaf_type       TEXT NOT NULL,
                    class_index     INTEGER NOT NULL,
                    class_name      TEXT NOT NULL,
                    confidence      REAL NOT NULL,
                    all_confidences TEXT,
                    inference_time_ms REAL,
                    image_path      TEXT,
                    created_at      TEXT NOT NULL,
                    is_synced       INTEGER NOT NULL DEFAULT 0,
                    synced_at       TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_pred_synced ON predictions(is_synced);
                CREATE INDEX IF NOT EXISTS idx_pred_synced_id ON predictions(is_synced, id);
            """)
            self.conn.commit()

            # Add device_id column (backward-compatible: NULL for old records)
            try:
                self.conn.execute(
                    "ALTER TABLE predictions ADD COLUMN device_id TEXT"
                )
                self.conn.commit()
            except sqlite3.OperationalError:
                pass  # Column already exists

    def save_prediction(self, leaf_type, result, image_path=None, device_id=None):
        """Save a prediction result to the database.

        Raises:
            OSError: If available disk space is below threshold.
        """
        free = shutil.disk_usage(os.path.dirname(self.db_path) or ".").free
        if free < _MIN_DISK_BYTES:
            logger.error(
                "Disk space too low (%.1f MB free) — skipping save",
                free / (1024 * 1024),
            )
            raise OSError(f"Insufficient disk space: {free} bytes free")

        with self._lock:
            self.conn.execute(
                """INSERT INTO predictions
                   (leaf_type, class_index, class_name, confidence,
                    all_confidences, inference_time_ms, image_path, device_id,
                    created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))""",
                (
                    leaf_type,
                    result["class_index"],
                    result["class_name"],
                    result["confidence"],
                    json.dumps(result.get("all_confidences")),
                    result.get("inference_time_ms"),
                    image_path,
                    str(device_id) if device_id else None,
                ),
            )
            self.conn.commit()

    def get_unsynced(self, limit=50):
        """Get unsynced predictions."""
        with self._lock:
            cursor = self.conn.execute(
                "SELECT * FROM predictions WHERE is_synced = 0 ORDER BY id LIMIT ?",
                (limit,),
            )
            columns = [d[0] for d in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def mark_synced(self, pred_id):
        """Mark a prediction as synced."""
        with self._lock:
            self.conn.execute(
                "UPDATE predictions SET is_synced = 1, synced_at = datetime('now') WHERE id = ?",
                (pred_id,),
            )
            self.conn.commit()

    def get_stats(self):
        """Get basic statistics."""
        with self._lock:
            total = self.conn.execute(
                "SELECT COUNT(*) FROM predictions"
            ).fetchone()[0]
            synced = self.conn.execute(
                "SELECT COUNT(*) FROM predictions WHERE is_synced = 1"
            ).fetchone()[0]
            last_pred = self.conn.execute(
                "SELECT created_at FROM predictions ORDER BY id DESC LIMIT 1"
            ).fetchone()
            return {
                "total_predictions": total,
                "synced": synced,
                "unsynced": total - synced,
                "last_prediction": last_pred[0] if last_pred else None,
            }

    def cleanup_old_records(self, max_records=10000):
        """Remove oldest predictions beyond max_records.

        Also deletes orphaned image files referenced by the removed rows
        to prevent unbounded disk usage.
        """
        with self._lock:
            # Collect image paths of rows that will be deleted
            cursor = self.conn.execute("""
                SELECT image_path FROM predictions
                WHERE id NOT IN (
                    SELECT id FROM predictions
                    ORDER BY created_at DESC
                    LIMIT ?
                ) AND image_path IS NOT NULL
            """, (max_records,))
            image_paths = [row[0] for row in cursor.fetchall()]

            # Delete the rows
            self.conn.execute("""
                DELETE FROM predictions
                WHERE id NOT IN (
                    SELECT id FROM predictions
                    ORDER BY created_at DESC
                    LIMIT ?
                )
            """, (max_records,))
            self.conn.commit()

        # Delete orphaned image files OUTSIDE the lock (I/O can be slow)
        for path in image_paths:
            try:
                if os.path.isfile(path):
                    os.unlink(path)
            except OSError as e:
                logger.warning("Failed to delete orphaned image %s: %s", path, e)

    def close(self):
        with self._lock:
            self.conn.close()
