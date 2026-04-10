-- ============================================================================
-- Migration 016: Add foreign key constraints
-- - model_benchmarks.leaf_type -> model_registry.leaf_type
-- - model_versions.leaf_type -> model_registry.leaf_type
-- ============================================================================
-- Safe to re-run: uses IF NOT EXISTS check via DO block.
-- ============================================================================

-- Step 0: Ensure model_registry.leaf_type has a UNIQUE constraint
-- (001_tables.sql defines it as UNIQUE, but guard in case of schema drift)
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage ccu
          ON tc.constraint_name = ccu.constraint_name
        WHERE tc.table_schema = 'public'
          AND tc.table_name = 'model_registry'
          AND tc.constraint_type = 'UNIQUE'
          AND ccu.column_name = 'leaf_type'
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
