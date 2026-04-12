-- ============================================================
-- Migration 020: Device Sync RPC Functions
-- ============================================================
-- Replaces direct REST queries with SECURITY DEFINER RPCs.
-- Root cause: Supabase gateway does not forward custom HTTP
-- headers (X-Device-Token) to PostgREST, so RLS policies that
-- use current_setting('request.header.x-device-token') always
-- evaluate to NULL → device queries return empty results.
--
-- Solution: RPC functions accept device_token as a parameter
-- and run with SECURITY DEFINER (same pattern as provision_device).
-- ============================================================

-- 1. Poll config, user assignment, and status
--    Called every sync interval (default 300s) by Jetson sync_engine
CREATE OR REPLACE FUNCTION public.device_poll_config(p_device_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
    v_device RECORD;
BEGIN
    SELECT desired_config, config_version, status, user_id
    INTO v_device
    FROM public.devices
    WHERE device_token = p_device_token;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'desired_config', v_device.desired_config,
        'config_version', v_device.config_version,
        'status', v_device.status,
        'user_id', v_device.user_id
    );
END;
$$;

-- 2. ACK applied config back to Supabase
--    Sets reported_config = desired_config so dashboard shows "Synced"
CREATE OR REPLACE FUNCTION public.device_ack_config(
    p_device_token UUID,
    p_reported_config JSONB
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
BEGIN
    UPDATE public.devices
    SET reported_config = p_reported_config,
        status = 'online'
    WHERE device_token = p_device_token;
END;
$$;

-- 3. Heartbeat: update last_seen_at (+ status if assigned)
--    Best-effort, called every sync cycle
CREATE OR REPLACE FUNCTION public.device_heartbeat(p_device_token UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
    v_has_user BOOLEAN;
BEGIN
    SELECT (user_id IS NOT NULL) INTO v_has_user
    FROM public.devices
    WHERE device_token = p_device_token;

    IF NOT FOUND THEN RETURN; END IF;

    IF v_has_user THEN
        UPDATE public.devices
        SET last_seen_at = now(), status = 'online'
        WHERE device_token = p_device_token;
    ELSE
        UPDATE public.devices
        SET last_seen_at = now()
        WHERE device_token = p_device_token;
    END IF;
END;
$$;

-- 4. Push predictions batch (replaces direct INSERT into predictions table)
--    Validates device ownership before inserting
CREATE OR REPLACE FUNCTION public.device_push_predictions(
    p_device_token UUID,
    p_predictions JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE
    v_device_id BIGINT;
    v_user_id UUID;
    v_pred JSONB;
    v_count INTEGER := 0;
BEGIN
    -- Validate device and get assigned user
    SELECT id, user_id INTO v_device_id, v_user_id
    FROM public.devices
    WHERE device_token = p_device_token;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'DEVICE_NOT_ASSIGNED';
    END IF;

    -- Insert each prediction
    -- Note: 'source' column is defined in 001_tables.sql but may not exist
    -- in older deployments. We skip it; device_id already identifies origin.
    FOR v_pred IN SELECT * FROM jsonb_array_elements(p_predictions)
    LOOP
        INSERT INTO public.predictions (
            user_id, leaf_type, predicted_class_index, predicted_class_name,
            confidence, all_confidences, inference_time_ms, model_version,
            created_at, device_id, local_id, image_url
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
            v_pred->>'image_url'
        )
        ON CONFLICT DO NOTHING;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

-- Grant execute to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.device_poll_config(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.device_ack_config(UUID, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.device_heartbeat(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.device_push_predictions(UUID, JSONB) TO anon, authenticated;

-- 5. Enable Realtime for devices table (dashboard auto-refresh)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND tablename = 'devices'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.devices;
        RAISE NOTICE 'Added devices to supabase_realtime publication';
    ELSE
        RAISE NOTICE 'devices already in supabase_realtime publication';
    END IF;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE WARNING 'Cannot alter publication — run manually: ALTER PUBLICATION supabase_realtime ADD TABLE public.devices;';
END $$;
