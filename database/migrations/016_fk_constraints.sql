-- ============================================================================
-- Migration 016: Add foreign key constraints
-- - model_benchmarks.leaf_type -> model_registry.leaf_type
-- - model_versions.leaf_type -> model_registry.leaf_type
-- ============================================================================
-- Safe to re-run: uses IF NOT EXISTS check via DO block.
-- ============================================================================

-- Step 0: Ensure model_registry.leaf_type has a UNIQUE constraint
-- Uses pg_constraint (more reliable than information_schema for this check)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class r ON c.conrelid = r.oid
        JOIN pg_namespace n ON r.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND r.relname = 'model_registry'
          AND c.contype IN ('u', 'p')
          AND EXISTS (
              SELECT 1 FROM pg_attribute a
              WHERE a.attrelid = r.oid
                AND a.attnum = ANY(c.conkey)
                AND a.attname = 'leaf_type'
          )
    ) THEN
        ALTER TABLE public.model_registry
            ADD CONSTRAINT model_registry_leaf_type_key UNIQUE (leaf_type);
    END IF;
END $$;

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
