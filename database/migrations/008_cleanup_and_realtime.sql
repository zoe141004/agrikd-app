-- =============================================================================
-- AgriKD — 008: Remove float32 benchmarks + Enable Realtime + Update RPC
-- =============================================================================
-- 1. Normalize & clean model_benchmarks format values
-- 2. Update get_leaf_type_options() to include model_registry leaf types
-- 3. Enable Realtime for pipeline_runs (required for dashboard live tracking)
-- =============================================================================
-- Safe to re-run: idempotent. Uses TRUNCATE+re-insert to bypass all constraint
-- issues from partial previous runs.
-- =============================================================================

-- ── 1. Rebuild model_benchmarks with clean format values ──────────────────────
-- Strategy: backup → truncate → drop all constraints → add correct constraint
--           → re-insert clean data. This is the only approach guaranteed to work
--           regardless of how many partial migration runs happened before.

-- 1a. Backup clean data to a temp table, normalizing format values
CREATE TEMP TABLE _benchmarks_clean AS
SELECT id, leaf_type, version,
       CASE
           WHEN LOWER(TRIM(format)) IN ('tflite', 'tflite_float16') THEN 'tflite_float16'
           ELSE LOWER(TRIM(format))
       END AS format,
       accuracy, precision_macro, recall_macro, f1_macro,
       per_class_metrics, confusion_matrix,
       latency_mean_ms, latency_p99_ms, fps, size_mb,
       flops_m, params_m, memory_mb, kl_divergence,
       is_candidate, created_at
FROM public.model_benchmarks
WHERE LOWER(TRIM(format)) IN ('pytorch', 'onnx', 'tflite', 'tflite_float16');

-- 1b. Deduplicate: if renaming 'tflite' → 'tflite_float16' creates duplicates
--     on the UNIQUE(leaf_type, version, format), keep the newer row
DELETE FROM _benchmarks_clean a
USING _benchmarks_clean b
WHERE a.leaf_type = b.leaf_type
  AND a.version   = b.version
  AND a.format    = b.format
  AND a.created_at < b.created_at;

-- 1c. Empty the real table
TRUNCATE public.model_benchmarks;

-- 1d. Drop ALL check constraints on the table (any name, any column)
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT conname
        FROM pg_constraint
        WHERE conrelid = 'public.model_benchmarks'::regclass
          AND contype = 'c'
    LOOP
        EXECUTE format('ALTER TABLE public.model_benchmarks DROP CONSTRAINT %I', r.conname);
        RAISE NOTICE 'Dropped check constraint: %', r.conname;
    END LOOP;
END $$;

-- 1e. Add the definitive CHECK constraint (table is empty → cannot fail)
ALTER TABLE public.model_benchmarks
    ADD CONSTRAINT model_benchmarks_format_check
        CHECK (format IN ('pytorch', 'onnx', 'tflite_float16'));

-- 1f. Re-insert clean data
INSERT INTO public.model_benchmarks
SELECT * FROM _benchmarks_clean;

-- 1g. Cleanup
DROP TABLE _benchmarks_clean;

-- ── 2. Update get_leaf_type_options() RPC ────────────────────────────────────
-- Now includes leaf types from model_registry so a leaf type appears
-- immediately after model upload, even before any predictions exist.
CREATE OR REPLACE FUNCTION get_leaf_type_options()
RETURNS TABLE(leaf_type TEXT) AS $$
    SELECT DISTINCT leaf_type FROM (
        SELECT leaf_type FROM public.predictions
        UNION
        SELECT leaf_type FROM public.model_registry
    ) combined
    ORDER BY leaf_type;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ── 3. Enable Realtime for pipeline_runs ─────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND tablename = 'pipeline_runs'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.pipeline_runs;
        RAISE NOTICE 'Added pipeline_runs to supabase_realtime publication';
    ELSE
        RAISE NOTICE 'pipeline_runs already in supabase_realtime publication';
    END IF;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE WARNING 'Cannot alter publication — run this manually in Supabase Dashboard: ALTER PUBLICATION supabase_realtime ADD TABLE public.pipeline_runs;';
END $$;
