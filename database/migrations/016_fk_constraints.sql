-- ============================================================================
-- Migration 016: Add foreign key constraints
-- - model_benchmarks.leaf_type -> model_registry.leaf_type
-- - model_versions.leaf_type -> model_registry.leaf_type
-- ============================================================================
-- Safe to re-run: uses IF NOT EXISTS check via DO block.
-- ============================================================================

-- model_benchmarks -> model_registry (leaf_type)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_benchmarks_leaf_type'
          AND table_name = 'model_benchmarks'
    ) THEN
        ALTER TABLE public.model_benchmarks
            ADD CONSTRAINT fk_model_benchmarks_leaf_type
            FOREIGN KEY (leaf_type) REFERENCES public.model_registry(leaf_type)
            ON DELETE CASCADE;
    END IF;
END $$;

-- model_versions -> model_registry (leaf_type)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_versions_leaf_type'
          AND table_name = 'model_versions'
    ) THEN
        ALTER TABLE public.model_versions
            ADD CONSTRAINT fk_model_versions_leaf_type
            FOREIGN KEY (leaf_type) REFERENCES public.model_registry(leaf_type)
            ON DELETE CASCADE;
    END IF;
END $$;
