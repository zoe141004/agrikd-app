-- ============================================================================
-- Migration 009: Security Hardening
-- - Add SET search_path to ALL SECURITY DEFINER functions
-- - Add DEFAULT for model_registry.updated_at
-- ============================================================================
-- Safe to re-run: CREATE OR REPLACE, ALTER SET DEFAULT is idempotent.
-- ============================================================================

-- 1. Fix ALL SECURITY DEFINER functions: add SET search_path = public, pg_catalog
--    This prevents search_path hijacking attacks on SECURITY DEFINER functions.

-- ── From 002_functions_triggers.sql ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_admin_role()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin'
    );
$$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, role)
    VALUES (NEW.id, NEW.email, 'user')
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

-- Note: sync_model_urls is superseded by enforce_version_lifecycle (migration 007)
-- but we harden it anyway in case it's still referenced.
CREATE OR REPLACE FUNCTION public.sync_model_urls()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.model_url IS NOT NULL THEN
        NEW.file_url := NEW.model_url;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

-- ── From 006_model_reports_and_rpcs.sql ──────────────────────────────────────

CREATE OR REPLACE FUNCTION get_dashboard_stats(p_leaf_type TEXT DEFAULT NULL)
RETURNS JSON AS $$
    SELECT json_build_object(
        'total', COUNT(*),
        'unique_users', COUNT(DISTINCT user_id),
        'avg_confidence', ROUND(AVG(confidence)::numeric, 3),
        'high_confidence_count', COUNT(*) FILTER (WHERE confidence >= 0.8),
        'low_confidence_count', COUNT(*) FILTER (WHERE confidence < 0.5)
    ) FROM predictions
    WHERE (p_leaf_type IS NULL OR leaf_type = p_leaf_type);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION get_disease_distribution(p_leaf_type TEXT DEFAULT NULL)
RETURNS TABLE(name TEXT, type TEXT, count BIGINT) AS $$
    SELECT predicted_class_name, leaf_type, COUNT(*)
    FROM predictions
    WHERE (p_leaf_type IS NULL OR predictions.leaf_type = p_leaf_type)
    GROUP BY predicted_class_name, predictions.leaf_type
    ORDER BY COUNT(*) DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

-- ── From 008_cleanup_and_realtime.sql ────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_leaf_type_options()
RETURNS TABLE(leaf_type TEXT) AS $$
    SELECT DISTINCT leaf_type FROM (
        SELECT leaf_type FROM public.predictions
        UNION
        SELECT leaf_type FROM public.model_registry
    ) combined
    ORDER BY leaf_type;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

-- ── From 007_multi_version.sql ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.enforce_version_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    active_count INT;
    oldest_active_id UUID;
BEGIN
    -- Guard against recursive trigger calls
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

    -- Backward compat: sync file_url = model_url for old Flutter clients
    IF NEW.model_url IS NOT NULL THEN
        NEW.file_url := NEW.model_url;
    END IF;

    -- When status transitions to 'active', enforce max 2 active per leaf_type
    IF NEW.status = 'active'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'active')
    THEN
        SELECT COUNT(*) INTO active_count
        FROM public.model_registry
        WHERE leaf_type = NEW.leaf_type
          AND status = 'active'
          AND id IS DISTINCT FROM NEW.id;

        IF active_count >= 2 THEN
            -- Demote the lowest version to 'backup'
            -- Use semantic version comparison (int array) instead of text sort
            SELECT id INTO oldest_active_id
            FROM public.model_registry
            WHERE leaf_type = NEW.leaf_type
              AND status = 'active'
              AND id IS DISTINCT FROM NEW.id
            ORDER BY string_to_array(version, '.')::int[] ASC
            LIMIT 1
            FOR UPDATE;

            UPDATE public.model_registry
            SET status = 'backup', updated_at = now()
            WHERE id = oldest_active_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

-- 2. Fix model_registry.updated_at: add DEFAULT now()
ALTER TABLE public.model_registry
    ALTER COLUMN updated_at SET DEFAULT now();
