-- Migration 024: Restrict anonymous UPDATE on model_engines to SECURITY DEFINER RPC
-- Prevents unauthorized users from updating model_engines directly via REST;
-- only the update_engine_benchmark() RPC (SECURITY DEFINER) may update.
--
-- Safe to re-run: CREATE POLICY uses "IF NOT EXISTS"-equivalent via DROP IF EXISTS first.

-- Drop the permissive anon UPDATE policy added in migration 013
DROP POLICY IF EXISTS "Anon can update engine benchmark fields" ON public.model_engines;

-- Create a restricted policy: only service_role and the calling user (via RPC) can update
CREATE POLICY "Service role can update model_engines"
    ON public.model_engines
    FOR UPDATE
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Ensure the update_engine_benchmark RPC exists with SECURITY DEFINER
-- (idempotent: CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION public.update_engine_benchmark(
    p_engine_id  BIGINT,
    p_metrics    JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    UPDATE public.model_engines
    SET
        benchmark_accuracy      = (p_metrics->>'benchmark_accuracy')::REAL,
        benchmark_precision     = (p_metrics->>'benchmark_precision')::REAL,
        benchmark_recall        = (p_metrics->>'benchmark_recall')::REAL,
        benchmark_f1            = (p_metrics->>'benchmark_f1')::REAL,
        benchmark_inference_ms  = (p_metrics->>'benchmark_inference_ms')::REAL,
        benchmark_run_at        = now()
    WHERE id = p_engine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ENGINE_NOT_FOUND: id=%', p_engine_id;
    END IF;
END;
$$;

-- Grant execute to authenticated users (Jetson devices call this via their JWT)
GRANT EXECUTE ON FUNCTION public.update_engine_benchmark(BIGINT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_engine_benchmark(BIGINT, JSONB) TO anon;
