-- =============================================================================
-- AgriKD — 004: Performance Indexes
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_predictions_user_id
    ON public.predictions (user_id);

CREATE INDEX IF NOT EXISTS idx_predictions_leaf_type
    ON public.predictions (leaf_type);

CREATE INDEX IF NOT EXISTS idx_predictions_created_at
    ON public.predictions (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_predictions_confidence
    ON public.predictions (confidence);

CREATE INDEX IF NOT EXISTS idx_audit_log_created_at
    ON public.audit_log (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_model_benchmarks_leaf_type
    ON public.model_benchmarks (leaf_type);

CREATE INDEX IF NOT EXISTS idx_model_versions_leaf_type
    ON public.model_versions (leaf_type);
