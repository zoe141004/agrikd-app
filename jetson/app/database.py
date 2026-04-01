"""SQLite database for Jetson edge predictions (WAL mode)."""

import json
import os
import sqlite3
import time


class JetsonDatabase:
    """Lightweight SQLite store for edge predictions."""

    def __init__(self, db_path):
        os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA busy_timeout=5000")
        self._create_tables()

    def _create_tables(self):
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
        """)
        self.conn.commit()

    def save_prediction(self, leaf_type, result, image_path=None):
        """Save a prediction result to the database."""
        self.conn.execute(
            """INSERT INTO predictions
               (leaf_type, class_index, class_name, confidence,
                all_confidences, inference_time_ms, image_path, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))""",
            (
                leaf_type,
                result["class_index"],
                result["class_name"],
                result["confidence"],
                json.dumps(result.get("all_confidences")),
                result.get("inference_time_ms"),
                image_path,
            ),
        )
        self.conn.commit()

    def get_unsynced(self, limit=50):
        """Get unsynced predictions."""
        cursor = self.conn.execute(
            "SELECT * FROM predictions WHERE is_synced = 0 ORDER BY id LIMIT ?",
            (limit,),
        )
        columns = [d[0] for d in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def mark_synced(self, pred_id):
        """Mark a prediction as synced."""
        self.conn.execute(
            "UPDATE predictions SET is_synced = 1, synced_at = datetime('now') WHERE id = ?",
            (pred_id,),
        )
        self.conn.commit()

    def get_stats(self):
        """Get basic statistics."""
        total = self.conn.execute("SELECT COUNT(*) FROM predictions").fetchone()[0]
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
        """Remove oldest predictions beyond max_records to prevent unbounded growth."""
        self.conn.execute("""
            DELETE FROM predictions
            WHERE id NOT IN (
                SELECT id FROM predictions
                ORDER BY created_at DESC
                LIMIT ?
            )
        """, (max_records,))
        self.conn.commit()

    def close(self):
        self.conn.close()
