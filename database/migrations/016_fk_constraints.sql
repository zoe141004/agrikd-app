-- ============================================================================
-- Migration 016: Add foreign key constraints
-- - model_benchmarks(leaf_type, version) -> model_registry(leaf_type, version)
-- - model_versions(leaf_type, version)   -> model_registry(leaf_type, version)
-- ============================================================================
-- Uses composite FK matching the existing model_registry_leaf_version_unique
-- constraint added by migration 007 (multi-version support).
-- Safe to re-run: uses IF NOT EXISTS check via DO block.
-- ============================================================================

-- Step 0: Remove orphaned rows before adding FK (ensure referential integrity)
DELETE FROM public.model_benchmarks
WHERE (leaf_type, version) NOT IN (
    SELECT leaf_type, version FROM public.model_registry
);

DELETE FROM public.model_versions
WHERE (leaf_type, version) NOT IN (
    SELECT leaf_type, version FROM public.model_registry
);

-- model_benchmarks(leaf_type, version) -> model_registry(leaf_type, version)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_benchmarks_leaf_version'
          AND table_name = 'model_benchmarks'
    ) THEN
        ALTER TABLE public.model_benchmarks
            ADD CONSTRAINT fk_model_benchmarks_leaf_version
            FOREIGN KEY (leaf_type, version)
            REFERENCES public.model_registry(leaf_type, version)
            ON DELETE CASCADE;
    END IF;
END $$;

-- model_versions(leaf_type, version) -> model_registry(leaf_type, version)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_versions_leaf_version'
          AND table_name = 'model_versions'
    ) THEN
        ALTER TABLE public.model_versions
            ADD CONSTRAINT fk_model_versions_leaf_version
            FOREIGN KEY (leaf_type, version)
            REFERENCES public.model_registry(leaf_type, version)
            ON DELETE CASCADE;
    END IF;
END $$;
