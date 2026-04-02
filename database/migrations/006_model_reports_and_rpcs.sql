-- =============================================================================
-- AgriKD — 006: Model Reports, Prediction Dedup, Dashboard RPCs
-- =============================================================================
-- Source of truth: database/migrations/
-- Safe to re-run: IF NOT EXISTS, CREATE OR REPLACE, DROP IF EXISTS.
-- =============================================================================

-- ── model_reports (user feedback on wrong predictions) ────────────────────

CREATE TABLE IF NOT EXISTS public.model_reports (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id         UUID REFERENCES auth.users(id),
    model_version   TEXT NOT NULL,
    leaf_type       TEXT NOT NULL,
    prediction_id   BIGINT REFERENCES predictions(id),
    reason          TEXT NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.model_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users insert own reports" ON public.model_reports;
CREATE POLICY "Users insert own reports"
    ON public.model_reports FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins read reports" ON public.model_reports;
CREATE POLICY "Admins read reports"
    ON public.model_reports FOR SELECT
    USING (public.is_admin_role());

-- ── Prediction dedup index (M1) ──────────────────────────────────────────
-- Prevent duplicate predictions from re-sync.
-- Partial index: only enforce when local_id IS NOT NULL.

CREATE UNIQUE INDEX IF NOT EXISTS idx_predictions_user_local_dedup
    ON public.predictions (user_id, local_id)
    WHERE local_id IS NOT NULL;

-- ── Dashboard RPC functions (C2) ─────────────────────────────────────────
-- Server-side aggregation to avoid the 1000-row default PostgREST limit.

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
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_disease_distribution(p_leaf_type TEXT DEFAULT NULL)
RETURNS TABLE(name TEXT, type TEXT, count BIGINT) AS $$
    SELECT predicted_class_name, leaf_type, COUNT(*)
    FROM predictions
    WHERE (p_leaf_type IS NULL OR predictions.leaf_type = p_leaf_type)
    GROUP BY predicted_class_name, predictions.leaf_type
    ORDER BY COUNT(*) DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_leaf_type_options()
RETURNS TABLE(leaf_type TEXT) AS $$
    SELECT DISTINCT leaf_type FROM predictions ORDER BY leaf_type;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
