-- ============================================================
-- Migration 018: Atomic provision_device RPC
-- Fixes: RLS blocks anon provisioning flow (token validation +
--         device registration + token claim must bypass RLS).
-- Replaces multi-step REST calls with a single SECURITY DEFINER
-- function that runs atomically in one transaction.
-- ============================================================

CREATE OR REPLACE FUNCTION public.provision_device(
    p_token_id   TEXT,
    p_hw_id      TEXT,
    p_hostname   TEXT    DEFAULT 'unknown',
    p_hw_info    JSONB   DEFAULT '{}'::jsonb,
    p_force      BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_token_row  public.provisioning_tokens%ROWTYPE;
    v_device     public.devices%ROWTYPE;
    v_device_id  BIGINT;
    v_device_token UUID;
BEGIN
    -- 1. Validate and lock provisioning token atomically
    --    SKIP LOCKED: concurrent callers get zero rows instead of blocking
    SELECT * INTO v_token_row
    FROM public.provisioning_tokens
    WHERE id       = p_token_id
      AND used_at  IS NULL
      AND expires_at > now()
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_TOKEN: Token not found, already claimed, or expired';
    END IF;

    -- 2. Check for existing device with same hw_id
    SELECT * INTO v_device
    FROM public.devices
    WHERE hw_id = p_hw_id
    FOR UPDATE;

    IF FOUND THEN
        -- Device exists: block unless decommissioned/unassigned or --force
        IF v_device.status IN ('online', 'offline', 'assigned') AND NOT p_force THEN
            RAISE EXCEPTION 'DEVICE_ACTIVE:%', v_device.status;
        END IF;

        -- Re-register: reset device to clean state
        UPDATE public.devices SET
            hostname        = p_hostname,
            hw_info         = p_hw_info,
            status          = 'unassigned',
            user_id         = NULL,
            reported_config = NULL,
            config_version  = 0
        WHERE id = v_device.id
        RETURNING id, device_token INTO v_device_id, v_device_token;
    ELSE
        -- New device
        INSERT INTO public.devices (hw_id, hostname, status, hw_info)
        VALUES (p_hw_id, p_hostname, 'unassigned', p_hw_info)
        RETURNING id, device_token INTO v_device_id, v_device_token;
    END IF;

    -- 3. Claim the provisioning token
    UPDATE public.provisioning_tokens SET
        used_at       = now(),
        used_by_hw_id = p_hw_id,
        device_id     = v_device_id
    WHERE id = p_token_id;

    -- 4. Return device credentials
    RETURN jsonb_build_object(
        'device_id',    v_device_id,
        'device_token', v_device_token
    );
END;
$$;

-- Allow anon role (provision.py uses the Supabase anon key)
GRANT EXECUTE ON FUNCTION public.provision_device(TEXT, TEXT, TEXT, JSONB, BOOLEAN) TO anon;
GRANT EXECUTE ON FUNCTION public.provision_device(TEXT, TEXT, TEXT, JSONB, BOOLEAN) TO authenticated;
