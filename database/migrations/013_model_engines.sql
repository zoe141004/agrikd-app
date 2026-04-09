-- ============================================================
-- Migration 013: Model Engines + ONNX URL support
-- Adds hardware-specific TensorRT engine tracking and
-- ONNX intermediate format URL to model_registry
-- ============================================================
-- Safe to re-run: IF NOT EXISTS, CREATE OR REPLACE, DROP IF EXISTS.
-- ============================================================

-- ============================================================
-- 1. Add ONNX columns to model_registry
-- ============================================================
ALTER TABLE public.model_registry
  ADD COLUMN IF NOT EXISTS onnx_url  TEXT,
  ADD COLUMN IF NOT EXISTS onnx_sha256 TEXT;

COMMENT ON COLUMN public.model_registry.onnx_url IS 'Supabase Storage URL for ONNX intermediate model';
COMMENT ON COLUMN public.model_registry.onnx_sha256 IS 'SHA-256 checksum of the ONNX file for integrity verification';

-- ============================================================
-- 2. Create model_engines table
--    Stores hardware-specific TensorRT .engine files
--    One engine per (leaf_type, version, hardware_tag)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.model_engines (
    id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    leaf_type         TEXT NOT NULL,
    version           TEXT NOT NULL,
    hardware_tag      TEXT NOT NULL,  -- e.g. 'sm53' (Nano), 'sm72' (Xavier), 'sm87' (Orin)
    engine_url        TEXT NOT NULL,
    engine_sha256     TEXT NOT NULL,
    benchmark_json    JSONB,          -- latency, throughput, accuracy from on-device validation
    created_by_device TEXT,           -- device_id that built this engine
    created_at        TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT fk_model_engines_registry
        FOREIGN KEY (leaf_type, version)
        REFERENCES public.model_registry (leaf_type, version)
        ON DELETE CASCADE,

    CONSTRAINT uq_model_engines_hw
        UNIQUE (leaf_type, version, hardware_tag)
);

CREATE INDEX IF NOT EXISTS idx_model_engines_lookup
    ON public.model_engines (leaf_type, version, hardware_tag);

COMMENT ON TABLE public.model_engines IS 'Hardware-specific TensorRT engine files built from ONNX models';

-- ============================================================
-- 3. RLS policies for model_engines
-- ============================================================
ALTER TABLE public.model_engines ENABLE ROW LEVEL SECURITY;

-- Public read: Jetson devices and apps can query available engines
DROP POLICY IF EXISTS "Anyone can read engines" ON public.model_engines;
CREATE POLICY "Anyone can read engines"
    ON public.model_engines FOR SELECT
    USING (true);

-- Only admins and service_role can insert/update/delete engines
-- (Jetson uses service_role key for engine upload)
DROP POLICY IF EXISTS "Service role manages engines" ON public.model_engines;
CREATE POLICY "Service role manages engines"
    ON public.model_engines FOR INSERT
    WITH CHECK (
        public.is_admin_role()
        OR (auth.jwt() ->> 'role') = 'service_role'
    );

DROP POLICY IF EXISTS "Service role updates engines" ON public.model_engines;
CREATE POLICY "Service role updates engines"
    ON public.model_engines FOR UPDATE
    USING (
        public.is_admin_role()
        OR (auth.jwt() ->> 'role') = 'service_role'
    );

DROP POLICY IF EXISTS "Admins delete engines" ON public.model_engines;
CREATE POLICY "Admins delete engines"
    ON public.model_engines FOR DELETE
    USING (public.is_admin_role());

-- ============================================================
-- 4. RPC: Get latest ONNX URL for a leaf type
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_latest_onnx_url(p_leaf_type TEXT)
RETURNS TABLE (
    leaf_type TEXT,
    version TEXT,
    onnx_url TEXT,
    onnx_sha256 TEXT
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT
        mr.leaf_type,
        mr.version,
        mr.onnx_url,
        mr.onnx_sha256
    FROM public.model_registry mr
    WHERE mr.leaf_type = p_leaf_type
      AND mr.status = 'active'
      AND mr.onnx_url IS NOT NULL
    ORDER BY string_to_array(mr.version, '.')::int[] DESC
    LIMIT 1;
$$;

-- ============================================================
-- 5. RPC: Check if engine exists for hardware
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_engine_for_hardware(
    p_leaf_type TEXT,
    p_version TEXT,
    p_hardware_tag TEXT
)
RETURNS TABLE (
    engine_url TEXT,
    engine_sha256 TEXT,
    benchmark_json JSONB
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT
        me.engine_url,
        me.engine_sha256,
        me.benchmark_json
    FROM public.model_engines me
    WHERE me.leaf_type = p_leaf_type
      AND me.version = p_version
      AND me.hardware_tag = p_hardware_tag
    LIMIT 1;
$$;
