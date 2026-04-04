-- =============================================================================
-- AgriKD — 007: Multi-Version Model Registry + Pipeline Runs
-- =============================================================================
-- REQ-3: Max 2 ACTIVE versions per leaf_type (3rd → oldest demoted to backup)
-- REQ-7: Status lifecycle (staging → active → backup)
-- REQ-6: Pipeline run tracking via pipeline_runs table
-- =============================================================================
-- Safe to re-run: uses IF NOT EXISTS / IF EXISTS guards.
-- =============================================================================

-- ── 1. model_registry: Drop UNIQUE(leaf_type), add multi-version support ────

-- Drop the old single-version constraint
ALTER TABLE public.model_registry
    DROP CONSTRAINT IF EXISTS model_registry_leaf_type_key;

-- Add status column (replaces is_active boolean)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND column_name = 'status'
    ) THEN
        ALTER TABLE public.model_registry
            ADD COLUMN status TEXT DEFAULT 'staging'
                CHECK (status IN ('staging', 'active', 'backup'));
    END IF;
END $$;

-- Add pth_url column (source checkpoint reference)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND column_name = 'pth_url'
    ) THEN
        ALTER TABLE public.model_registry ADD COLUMN pth_url TEXT;
    END IF;
END $$;

-- Migrate existing data: is_active=true → status='active', else → 'staging'
UPDATE public.model_registry
SET status = CASE
    WHEN is_active = true THEN 'active'
    ELSE 'staging'
END
WHERE status IS NULL;

-- New unique constraint: one version per leaf_type
ALTER TABLE public.model_registry
    DROP CONSTRAINT IF EXISTS model_registry_leaf_version_unique;
ALTER TABLE public.model_registry
    ADD CONSTRAINT model_registry_leaf_version_unique
        UNIQUE(leaf_type, version);

-- Index for fast lookup of active models
CREATE INDEX IF NOT EXISTS idx_model_registry_active
    ON public.model_registry(leaf_type, updated_at DESC)
    WHERE status = 'active';

-- Index for status queries
CREATE INDEX IF NOT EXISTS idx_model_registry_status
    ON public.model_registry(status);

-- NOTE: Deprecated columns kept for backward compatibility (not dropped):
-- is_active, model_url_float32, sha256_float32, active_tflite_variant, file_url


-- ── 2. Replace sync_model_urls() with enforce_version_lifecycle() ───────────

-- Drop old variant-routing triggers
DROP TRIGGER IF EXISTS sync_model_urls_trigger ON public.model_registry;
DROP TRIGGER IF EXISTS sync_model_urls_insert_trigger ON public.model_registry;

CREATE OR REPLACE FUNCTION public.enforce_version_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    active_count INT;
    oldest_active_id UUID;
BEGIN
    -- Guard against recursive trigger calls
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

    -- Backward compat: sync file_url = model_url for old Flutter clients
    IF NEW.model_url IS NOT NULL THEN
        NEW.file_url := NEW.model_url;
    END IF;

    -- When status transitions to 'active', enforce max 2 active per leaf_type
    IF NEW.status = 'active'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'active')
    THEN
        SELECT COUNT(*) INTO active_count
        FROM public.model_registry
        WHERE leaf_type = NEW.leaf_type
          AND status = 'active'
          AND id IS DISTINCT FROM NEW.id
        FOR UPDATE;

        IF active_count >= 2 THEN
            -- Demote the oldest active version to 'backup'
            SELECT id INTO oldest_active_id
            FROM public.model_registry
            WHERE leaf_type = NEW.leaf_type
              AND status = 'active'
              AND id IS DISTINCT FROM NEW.id
            ORDER BY updated_at ASC
            LIMIT 1
            FOR UPDATE;

            UPDATE public.model_registry
            SET status = 'backup', updated_at = now()
            WHERE id = oldest_active_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS enforce_version_lifecycle_trigger ON public.model_registry;
CREATE TRIGGER enforce_version_lifecycle_trigger
    BEFORE INSERT OR UPDATE ON public.model_registry
    FOR EACH ROW EXECUTE FUNCTION public.enforce_version_lifecycle();


-- ── 3. pipeline_runs table (REQ-6: pipeline progress tracking) ──────────────

CREATE TABLE IF NOT EXISTS public.pipeline_runs (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    leaf_type       TEXT NOT NULL,
    version         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'converting', 'evaluating',
                                      'uploading', 'completed', 'failed')),
    github_run_id   BIGINT,
    github_run_url  TEXT,
    error_message   TEXT,
    started_at      TIMESTAMPTZ DEFAULT now(),
    completed_at    TIMESTAMPTZ,
    triggered_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_pipeline_runs_leaf_version
    ON public.pipeline_runs(leaf_type, version, started_at DESC);


-- ── 4. RLS for pipeline_runs ────────────────────────────────────────────────

ALTER TABLE public.pipeline_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view pipeline runs" ON public.pipeline_runs;
CREATE POLICY "Anyone can view pipeline runs"
    ON public.pipeline_runs FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Admins manage pipeline runs" ON public.pipeline_runs;
CREATE POLICY "Admins manage pipeline runs"
    ON public.pipeline_runs FOR ALL
    USING (public.is_admin_role());

-- NOTE: GitHub Actions uses service_role key which bypasses RLS entirely.


-- ── 5. Enable Supabase Realtime for pipeline_runs ───────────────────────────
-- Run this in Supabase Dashboard → SQL Editor:
-- ALTER PUBLICATION supabase_realtime ADD TABLE public.pipeline_runs;
-- (Cannot be run via migrations — requires superuser privileges)
