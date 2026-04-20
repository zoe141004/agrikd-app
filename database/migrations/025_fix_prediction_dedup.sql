-- Migration 025: Fix prediction local_id collision between Flutter and Jetson
--
-- ROOT CAUSE: Both Flutter (mobile) and Jetson use SQLite auto-increment IDs
-- starting from 1. The single dedup index (user_id, local_id) caused silent
-- data loss when the same user had predictions from both sources with the same
-- local_id value.
--
-- SOLUTION: Replace with two partial unique indexes that distinguish source:
--   - Mobile rows:  device_id IS NULL     → index on (user_id, local_id)
--   - Jetson rows:  device_id IS NOT NULL → index on (user_id, device_id, local_id)
--
-- PostgREST correctly infers the mobile index for Flutter upserts because:
--   1. Column set (user_id, local_id) matches exactly
--   2. Flutter rows never include device_id → it defaults to NULL
--   3. The partial WHERE condition is satisfied automatically
--
-- Safe to re-run: DROP IF EXISTS + CREATE ... IF NOT EXISTS

-- Step 1: Drop the old single non-partial index that caused collisions
DROP INDEX IF EXISTS public.idx_predictions_user_local_dedup;

-- Step 2: Partial index for Flutter mobile predictions (device_id IS NULL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_predictions_mobile_dedup
    ON public.predictions (user_id, local_id)
    WHERE local_id IS NOT NULL AND device_id IS NULL;

-- Step 3: Partial index for Jetson device predictions (device_id IS NOT NULL)
CREATE UNIQUE INDEX IF NOT EXISTS idx_predictions_device_dedup
    ON public.predictions (user_id, device_id, local_id)
    WHERE local_id IS NOT NULL AND device_id IS NOT NULL;

-- Step 4: Replace device_push_predictions RPC to also set source='jetson'
-- (previously it omitted source, leaving NULL which obscured the data origin)
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

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;
