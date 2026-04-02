-- =============================================================================
-- AgriKD — 002: Row Level Security Policies
-- =============================================================================
-- Source of truth: admin-dashboard/supabase-schema.sql
-- Safe to re-run: DROP IF EXISTS before each CREATE POLICY.
-- =============================================================================

-- ── Enable RLS on all tables ────────────────────────────────────────────────

ALTER TABLE public.predictions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_registry   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_benchmarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.model_versions   ENABLE ROW LEVEL SECURITY;

-- ── predictions ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Users read own predictions" ON public.predictions;
CREATE POLICY "Users read own predictions"
    ON public.predictions FOR SELECT
    USING (auth.uid() = user_id OR public.is_admin_role());

DROP POLICY IF EXISTS "Users insert own predictions" ON public.predictions;
CREATE POLICY "Users insert own predictions"
    ON public.predictions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins update predictions" ON public.predictions;
CREATE POLICY "Admins update predictions"
    ON public.predictions FOR UPDATE
    USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete predictions" ON public.predictions;
CREATE POLICY "Admins delete predictions"
    ON public.predictions FOR DELETE
    USING (public.is_admin_role());

-- ── model_registry ──────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Anyone can read models" ON public.model_registry;
CREATE POLICY "Anyone can read models"
    ON public.model_registry FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Admins insert models" ON public.model_registry;
CREATE POLICY "Admins insert models"
    ON public.model_registry FOR INSERT
    WITH CHECK (public.is_admin_role());

DROP POLICY IF EXISTS "Admins update models" ON public.model_registry;
CREATE POLICY "Admins update models"
    ON public.model_registry FOR UPDATE
    USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete models" ON public.model_registry;
CREATE POLICY "Admins delete models"
    ON public.model_registry FOR DELETE
    USING (public.is_admin_role());

-- ── profiles ────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Users read own profile" ON public.profiles;
CREATE POLICY "Users read own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id OR public.is_admin_role());

DROP POLICY IF EXISTS "Admins manage profiles" ON public.profiles;
CREATE POLICY "Admins manage profiles"
    ON public.profiles FOR ALL
    USING (public.is_admin_role());

-- ── audit_log ───────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Admins read audit log" ON public.audit_log;
CREATE POLICY "Admins read audit log"
    ON public.audit_log FOR SELECT
    USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins insert audit log" ON public.audit_log;
CREATE POLICY "Admins insert audit log"
    ON public.audit_log FOR INSERT
    WITH CHECK (public.is_admin_role());

-- ── model_benchmarks ────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Anyone can read benchmarks" ON public.model_benchmarks;
CREATE POLICY "Anyone can read benchmarks"
    ON public.model_benchmarks FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Admins insert benchmarks" ON public.model_benchmarks;
CREATE POLICY "Admins insert benchmarks"
    ON public.model_benchmarks FOR INSERT
    WITH CHECK (public.is_admin_role());

DROP POLICY IF EXISTS "Admins update benchmarks" ON public.model_benchmarks;
CREATE POLICY "Admins update benchmarks"
    ON public.model_benchmarks FOR UPDATE
    USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete benchmarks" ON public.model_benchmarks;
CREATE POLICY "Admins delete benchmarks"
    ON public.model_benchmarks FOR DELETE
    USING (public.is_admin_role());

-- ── model_versions ──────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Anyone can read model versions" ON public.model_versions;
CREATE POLICY "Anyone can read model versions"
    ON public.model_versions FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "Admins manage model versions" ON public.model_versions;
CREATE POLICY "Admins manage model versions"
    ON public.model_versions FOR ALL
    USING (public.is_admin_role());
