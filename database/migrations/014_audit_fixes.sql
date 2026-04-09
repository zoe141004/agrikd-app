-- ============================================================================
-- Migration 014: Production Audit Fixes — Security & RLS Hardening
-- ============================================================================
-- Fixes from Production Readiness Audit Round 1:
--   DB-C2: Dashboard RPCs admin-only guard (bypass RLS via SECURITY DEFINER)
--   DB-H3: profiles UPDATE policy for users (own profile)
--   DB-H4: model_reports SELECT policy for users (own reports)
--   DB-M1: Missing audit_log.user_id index
-- Safe to re-run: CREATE OR REPLACE, DROP IF EXISTS, IF NOT EXISTS.
-- ============================================================================

-- ── DB-C2: Dashboard RPCs — add admin-only guard ──────────────────────────
-- These functions use SECURITY DEFINER which bypasses RLS on predictions.
-- Without guard, ANY authenticated user can see system-wide aggregates.
-- Convert from SQL to PL/pgSQL to add is_admin_role() check.

CREATE OR REPLACE FUNCTION get_dashboard_stats(p_leaf_type TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    IF NOT public.is_admin_role() THEN
        RAISE EXCEPTION 'Permission denied: admin role required'
            USING ERRCODE = '42501';  -- insufficient_privilege
    END IF;

    RETURN (
        SELECT json_build_object(
            'total', COUNT(*),
            'unique_users', COUNT(DISTINCT user_id),
            'avg_confidence', ROUND(AVG(confidence)::numeric, 3),
            'high_confidence_count', COUNT(*) FILTER (WHERE confidence >= 0.8),
            'low_confidence_count', COUNT(*) FILTER (WHERE confidence < 0.5)
        ) FROM predictions
        WHERE (p_leaf_type IS NULL OR leaf_type = p_leaf_type)
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_disease_distribution(p_leaf_type TEXT DEFAULT NULL)
RETURNS TABLE(name TEXT, type TEXT, count BIGINT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    IF NOT public.is_admin_role() THEN
        RAISE EXCEPTION 'Permission denied: admin role required'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
        SELECT predicted_class_name, predictions.leaf_type, COUNT(*)
        FROM predictions
        WHERE (p_leaf_type IS NULL OR predictions.leaf_type = p_leaf_type)
        GROUP BY predicted_class_name, predictions.leaf_type
        ORDER BY COUNT(*) DESC;
END;
$$;

CREATE OR REPLACE FUNCTION get_leaf_type_options()
RETURNS TABLE(leaf_type TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    IF NOT public.is_admin_role() THEN
        RAISE EXCEPTION 'Permission denied: admin role required'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
        SELECT combined.leaf_type FROM (
            SELECT p.leaf_type FROM public.predictions p
            UNION
            SELECT mr.leaf_type FROM public.model_registry mr
        ) combined
        ORDER BY combined.leaf_type;
END;
$$;

-- ── DB-H3: profiles — allow users to UPDATE their own profile ─────────────
-- Currently: users can SELECT own profile, admins can manage ALL.
-- Missing: users cannot update their own display_name, etc.

DROP POLICY IF EXISTS "Users update own profile" ON public.profiles;
CREATE POLICY "Users update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- ── DB-H4: model_reports — allow users to SELECT their own reports ────────
-- Currently: users can INSERT own reports, admins can SELECT all.
-- Missing: users cannot read back their own submitted reports.

DROP POLICY IF EXISTS "Users read own reports" ON public.model_reports;
CREATE POLICY "Users read own reports"
    ON public.model_reports FOR SELECT
    USING (auth.uid() = user_id OR public.is_admin_role());

-- ── DB-M1: audit_log — add user_id index for query performance ────────────
-- audit_log already has idx_audit_log_created_at (from 004).
-- Missing: user_id index for filtering audit entries by user.

CREATE INDEX IF NOT EXISTS idx_audit_log_user_id
    ON public.audit_log (user_id);
