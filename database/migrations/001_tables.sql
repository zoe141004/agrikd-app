-- =============================================================================
-- AgriKD — 001: Table Definitions
-- =============================================================================
-- Run in Supabase SQL Editor to create all tables.
-- Safe to re-run: uses IF NOT EXISTS.
--
-- TODO: Export your actual column definitions from Supabase Dashboard
--       (Database → Tables → each table → Definition tab) and paste here.
-- =============================================================================

-- Profiles (extended from auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       TEXT,
    role        TEXT DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    is_active   BOOLEAN DEFAULT true,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Predictions
CREATE TABLE IF NOT EXISTS public.predictions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    leaf_type       TEXT NOT NULL,
    predicted_class TEXT NOT NULL,
    confidence      REAL NOT NULL,
    model_version   TEXT,
    image_url       TEXT,
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT now()
    -- TODO: verify these columns match your actual Supabase schema
);

-- Model Registry
CREATE TABLE IF NOT EXISTS public.model_registry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    leaf_type       TEXT NOT NULL,
    version         TEXT NOT NULL,
    file_path       TEXT,
    download_url    TEXT,
    sha256_checksum TEXT,
    num_classes     INT,
    class_labels    JSONB,
    is_active       BOOLEAN DEFAULT false,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
    -- TODO: verify these columns match your actual Supabase schema
);

-- Audit Log
CREATE TABLE IF NOT EXISTS public.audit_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID,
    action      TEXT NOT NULL,
    table_name  TEXT,
    record_id   UUID,
    old_data    JSONB,
    new_data    JSONB,
    created_at  TIMESTAMPTZ DEFAULT now()
    -- TODO: verify these columns match your actual Supabase schema
);

-- Model Benchmarks
CREATE TABLE IF NOT EXISTS public.model_benchmarks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    leaf_type       TEXT NOT NULL,
    model_version   TEXT,
    format          TEXT,
    accuracy        REAL,
    latency_ms      REAL,
    model_size_mb   REAL,
    kl_divergence   REAL,
    created_at      TIMESTAMPTZ DEFAULT now()
    -- TODO: verify these columns match your actual Supabase schema
);

-- Model Versions
CREATE TABLE IF NOT EXISTS public.model_versions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    leaf_type       TEXT NOT NULL,
    version         TEXT NOT NULL,
    changelog       TEXT,
    created_by      UUID REFERENCES auth.users(id),
    created_at      TIMESTAMPTZ DEFAULT now()
    -- TODO: verify these columns match your actual Supabase schema
);
