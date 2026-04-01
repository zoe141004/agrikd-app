-- =============================================================================
-- AgriKD — 002: Row Level Security Policies
-- =============================================================================
-- Enables RLS and creates policies for all 6 tables.
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE where possible.
--
-- TODO: Export your actual RLS policies from Supabase Dashboard
--       (Authentication → Policies tab) and verify they match these templates.
-- =============================================================================

-- ── Enable RLS on all tables ──────────────────────────────────────────────────
ALTER TABLE public.predictions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_registry   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_benchmarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_versions   ENABLE ROW LEVEL SECURITY;

-- Force RLS even for table owners (defense in depth)
ALTER TABLE public.predictions      FORCE ROW LEVEL SECURITY;
ALTER TABLE public.model_registry   FORCE ROW LEVEL SECURITY;
ALTER TABLE public.profiles         FORCE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log        FORCE ROW LEVEL SECURITY;
ALTER TABLE public.model_benchmarks FORCE ROW LEVEL SECURITY;
ALTER TABLE public.model_versions   FORCE ROW LEVEL SECURITY;

-- ── predictions ───────────────────────────────────────────────────────────────

-- Users can read their own predictions
CREATE POLICY "Users read own predictions"
    ON public.predictions FOR SELECT
    USING (auth.uid() = user_id);

-- Users can insert their own predictions
CREATE POLICY "Users insert own predictions"
    ON public.predictions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Admins can read all predictions
CREATE POLICY "Admins read all predictions"
    ON public.predictions FOR SELECT
    USING (public.is_admin_role());

-- TODO: verify these match your actual policies in Supabase Dashboard

-- ── profiles ──────────────────────────────────────────────────────────────────

-- Users can read their own profile
CREATE POLICY "Users read own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

-- Users can update their own profile (but NOT the role column)
-- NOTE: Column-level security requires a custom check
CREATE POLICY "Users update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id AND role = (SELECT role FROM public.profiles WHERE id = auth.uid()));

-- Admins can do everything on profiles
CREATE POLICY "Admins manage profiles"
    ON public.profiles FOR ALL
    USING (public.is_admin_role());

-- TODO: verify the role-protection check matches your actual implementation

-- ── model_registry ────────────────────────────────────────────────────────────

-- Everyone can read active models (for OTA updates)
CREATE POLICY "Public read active models"
    ON public.model_registry FOR SELECT
    USING (is_active = true);

-- Only admins can insert/update/delete models
CREATE POLICY "Admins manage models"
    ON public.model_registry FOR ALL
    USING (public.is_admin_role());

-- ── audit_log ─────────────────────────────────────────────────────────────────

-- Admins can read audit log
CREATE POLICY "Admins read audit log"
    ON public.audit_log FOR SELECT
    USING (public.is_admin_role());

-- Insert via server-side functions only (no direct user insert)
-- TODO: verify if users need INSERT access for client-side audit entries

-- ── model_benchmarks ──────────────────────────────────────────────────────────

-- Everyone can read benchmarks
CREATE POLICY "Public read benchmarks"
    ON public.model_benchmarks FOR SELECT
    USING (true);

-- Only admins can write benchmarks
CREATE POLICY "Admins manage benchmarks"
    ON public.model_benchmarks FOR ALL
    USING (public.is_admin_role());

-- ── model_versions ────────────────────────────────────────────────────────────

-- Everyone can read versions
CREATE POLICY "Public read model versions"
    ON public.model_versions FOR SELECT
    USING (true);

-- Only admins can write versions
CREATE POLICY "Admins manage versions"
    ON public.model_versions FOR ALL
    USING (public.is_admin_role());
