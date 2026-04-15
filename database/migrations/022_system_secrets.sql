-- ============================================================
-- Migration 022: System Secrets Table
-- Provides a secure key-value store for shared secrets
-- (e.g., GCS service account key for DVC dataset access).
-- Devices fetch secrets via authenticated RPC calls.
-- ============================================================

-- Table: system_secrets (admin-managed key-value store)
CREATE TABLE IF NOT EXISTS public.system_secrets (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES auth.users(id)
);

COMMENT ON TABLE public.system_secrets IS
    'Shared secrets for system services (GCS keys, API tokens). '
    'Only admins can read/write via dashboard. Devices read via RPC.';

-- RLS: only service_role can directly access (no anon/authenticated)
ALTER TABLE public.system_secrets ENABLE ROW LEVEL SECURITY;

-- Admin read/write policy (via service_role or admin check)
CREATE POLICY "Admins can manage system_secrets"
    ON public.system_secrets
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- RPC: get_system_secret — for authenticated devices to fetch a secret by key
-- Validates device_token to ensure only provisioned devices can access secrets.
CREATE OR REPLACE FUNCTION public.get_system_secret(
    p_device_token UUID,
    p_key TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_device_id BIGINT;
    v_value TEXT;
BEGIN
    -- Validate device token
    SELECT id INTO v_device_id
    FROM public.devices
    WHERE device_token = p_device_token
      AND is_active = true;

    IF v_device_id IS NULL THEN
        RAISE EXCEPTION 'Invalid or inactive device token';
    END IF;

    -- Fetch secret value
    SELECT s.value INTO v_value
    FROM public.system_secrets s
    WHERE s.key = p_key;

    RETURN v_value;  -- NULL if key not found
END;
$$;

COMMENT ON FUNCTION public.get_system_secret IS
    'Fetch a system secret by key. Requires valid device_token for authentication.';

-- Grant execute to anon role (device uses anon key + device_token for auth)
GRANT EXECUTE ON FUNCTION public.get_system_secret TO anon;
GRANT EXECUTE ON FUNCTION public.get_system_secret TO authenticated;
