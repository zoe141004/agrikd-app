-- ============================================================
-- Migration 026: Fix engine benchmark RPC + close security gap
--
-- Fixes three bugs in migration 024:
--   1. RPC referenced 6 non-existent columns on model_engines
--      (benchmark_accuracy, etc.) — should use benchmark_json JSONB
--   2. Parameter p_engine_id was BIGINT but model_engines.id is UUID
--   3. DROP POLICY used wrong name ("Anon can update engine benchmark
--      fields") — correct name is "Jetson devices update engine
--      benchmark" from migration 023. The permissive anon UPDATE
--      policy was never dropped → security vulnerability.
--
-- Also fixes device_push_predictions return count (migration 025)
-- to only count actually inserted rows (not ON CONFLICT skips).
--
-- Safe to re-run: DROP IF EXISTS + CREATE OR REPLACE.
-- ============================================================

-- ── 1. Drop the broken function from migration 024 ──────────────────────────
--    (BIGINT signature — cannot match UUID primary key)
DROP FUNCTION IF EXISTS public.update_engine_benchmark(BIGINT, JSONB);

-- ── 2. Drop the permissive anon UPDATE policy from migration 023 ────────────
--    Policy name: "Jetson devices update engine benchmark"
--    This policy allowed ANY anon user to UPDATE any row on model_engines
--    with USING (true) WITH CHECK (true) — a security vulnerability.
DROP POLICY IF EXISTS "Jetson devices update engine benchmark" ON public.model_engines;

-- ── 3. Create fixed RPC with correct UUID type and benchmark_json column ────
CREATE OR REPLACE FUNCTION public.update_engine_benchmark(
    p_engine_id  UUID,
    p_metrics    JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    UPDATE public.model_engines
    SET benchmark_json = p_metrics
    WHERE id = p_engine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ENGINE_NOT_FOUND: id=%', p_engine_id;
    END IF;
END;
$$;

-- ── 4. Grant execute to roles that need to call this RPC ────────────────────
--    authenticated: Jetson devices via JWT
--    anon: Jetson devices via publishable key (for initial setup)
GRANT EXECUTE ON FUNCTION public.update_engine_benchmark(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_engine_benchmark(UUID, JSONB) TO anon;

-- ── 5. Fix device_push_predictions return count (from migration 025) ────────
--    Previously: v_count incremented unconditionally, including ON CONFLICT
--    DO NOTHING skips → misleading return value.
--    Fix: Use GET DIAGNOSTICS to only count actually inserted rows.
CREATE OR REPLACE FUNCTION public.device_push_predictions(
    p_device_token UUID,
    p_predictions  JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_device_id BIGINT;
    v_user_id   UUID;
    v_pred      JSONB;
    v_count     INTEGER := 0;
    v_rows      INTEGER;
BEGIN
    -- Resolve device token → device_id + owner user_id
    SELECT id, user_id
    INTO   v_device_id, v_user_id
    FROM   public.devices
    WHERE  device_token = p_device_token;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'DEVICE_NOT_ASSIGNED';
    END IF;

    -- Insert each prediction; silently skip exact duplicates
    FOR v_pred IN SELECT * FROM jsonb_array_elements(p_predictions) LOOP
        INSERT INTO public.predictions (
            user_id,
            leaf_type,
            predicted_class_index,
            predicted_class_name,
            confidence,
            all_confidences,
            inference_time_ms,
            model_version,
            created_at,
            device_id,
            local_id,
            image_url,
            source
        ) VALUES (
            v_user_id,
            v_pred->>'leaf_type',
            (v_pred->>'predicted_class_index')::INTEGER,
            v_pred->>'predicted_class_name',
            (v_pred->>'confidence')::REAL,
            v_pred->'all_confidences',
            (v_pred->>'inference_time_ms')::REAL,
            v_pred->>'model_version',
            COALESCE((v_pred->>'created_at')::TIMESTAMPTZ, now()),
            v_device_id,
            (v_pred->>'local_id')::INTEGER,
            v_pred->>'image_url',
            'jetson'
        )
        ON CONFLICT DO NOTHING;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_count := v_count + v_rows;
    END LOOP;

    RETURN v_count;
END;
$$;
