-- Migration 011: DVC Operations tracking table
-- Mirrors pipeline_runs pattern for data/DVC operations
-- Provides persistent status tracking, Realtime subscriptions, and workflow report-back

-- ── 1. dvc_operations table ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.dvc_operations (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    leaf_type       TEXT NOT NULL,
    operation       TEXT NOT NULL
                    CHECK (operation IN ('stage', 'push', 'pull', 'export')),
    source          TEXT
                    CHECK (source IS NULL OR source IN (
                        'predictions', 'gdrive', 'kaggle', 'manual', 'dvc_remote'
                    )),
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN (
                        'pending', 'staging', 'staged', 'pushing',
                        'pulling', 'exporting', 'completed', 'failed'
                    )),
    -- Flexible metadata (file_count, total_size, classes, confidence_threshold,
    --   source_url, staging_path, dvc_file, dvc_md5, staged_from_operation, display_name)
    metadata        JSONB DEFAULT '{}'::jsonb,

    -- GitHub Actions run tracking
    github_run_id   BIGINT,
    github_run_url  TEXT,
    error_message   TEXT,

    -- Timestamps
    started_at      TIMESTAMPTZ DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    triggered_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL
);


-- ── 2. Indexes ──────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_dvc_operations_leaf_type
    ON public.dvc_operations(leaf_type, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_dvc_operations_active
    ON public.dvc_operations(status)
    WHERE status NOT IN ('completed', 'failed');


-- ── 3. RLS policies (same pattern as pipeline_runs) ─────────────────────────

ALTER TABLE public.dvc_operations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view dvc operations" ON public.dvc_operations;
CREATE POLICY "Anyone can view dvc operations"
    ON public.dvc_operations FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Admins manage dvc operations" ON public.dvc_operations;
CREATE POLICY "Admins manage dvc operations"
    ON public.dvc_operations FOR ALL
    USING (public.is_admin_role());

-- NOTE: GitHub Actions uses service_role key which bypasses RLS entirely.


-- ── 4. Enable Supabase Realtime for dvc_operations ──────────────────────────
-- Run this in Supabase Dashboard → SQL Editor after applying this migration:
--   ALTER PUBLICATION supabase_realtime ADD TABLE public.dvc_operations;
-- (Cannot be run via migrations — requires superuser privileges)
