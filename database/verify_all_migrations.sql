-- =============================================================================
-- AgriKD — Comprehensive Migration Verification (001–007)
-- =============================================================================
-- Run in Supabase SQL Editor AFTER executing all 7 migrations.
-- Outputs a single results table with PASS/FAIL for every expected object.
-- Expected: 0 FAIL rows = database is fully set up.
-- =============================================================================

DO $$
DECLARE
    _pass INT := 0;
    _fail INT := 0;

    -- ── Helper: check if table exists ──
    _tbl TEXT;
    _required_tables TEXT[] := ARRAY[
        'profiles', 'predictions', 'model_registry', 'audit_log',
        'model_benchmarks', 'model_versions', 'model_reports', 'pipeline_runs'
    ];

    -- ── Helper: check column ──
    _col_check RECORD;

    -- ── Helper: check function ──
    _fn TEXT;
    _required_functions TEXT[] := ARRAY[
        'is_admin_role', 'handle_new_user', 'enforce_version_lifecycle',
        'get_dashboard_stats', 'get_disease_distribution', 'get_leaf_type_options'
    ];

    -- ── Helper: check trigger ──
    _trg RECORD;

    -- ── Helper: check index ──
    _idx TEXT;
    _required_indexes TEXT[] := ARRAY[
        'idx_predictions_user_id', 'idx_predictions_leaf_type',
        'idx_predictions_created_at', 'idx_predictions_confidence',
        'idx_audit_log_created_at', 'idx_model_benchmarks_leaf_type',
        'idx_model_versions_leaf_type', 'idx_predictions_user_local_dedup',
        'idx_model_registry_active', 'idx_model_registry_status',
        'idx_pipeline_runs_leaf_version'
    ];

    -- ── Helper: check RLS policy ──
    _pol TEXT;
    _required_policies TEXT[] := ARRAY[
        -- predictions (4)
        'Users read own predictions', 'Users insert own predictions',
        'Admins update predictions', 'Admins delete predictions',
        -- model_registry (4)
        'Anyone can read models', 'Admins insert models',
        'Admins update models', 'Admins delete models',
        -- profiles (2)
        'Users read own profile', 'Admins manage profiles',
        -- audit_log (2)
        'Admins read audit log', 'Admins insert audit log',
        -- model_benchmarks (4)
        'Anyone can read benchmarks', 'Admins insert benchmarks',
        'Admins update benchmarks', 'Admins delete benchmarks',
        -- model_versions (2)
        'Anyone can read model versions', 'Admins manage model versions',
        -- model_reports (2)
        'Users insert own reports', 'Admins read reports',
        -- pipeline_runs (2)
        'Anyone can view pipeline runs', 'Admins manage pipeline runs'
    ];

    -- ── Helper: check storage bucket ──
    _bkt TEXT;
    _required_buckets TEXT[] := ARRAY['models', 'datasets', 'prediction-images'];

    -- ── Temp vars ──
    _exists BOOLEAN;
    _col_type TEXT;

BEGIN
    -- Create temp results table
    DROP TABLE IF EXISTS _verify_results;
    CREATE TEMP TABLE _verify_results (
        section TEXT,
        item TEXT,
        status TEXT,
        detail TEXT
    );

    -- =====================================================================
    -- SECTION 1: Tables (001 + 006 + 007)
    -- =====================================================================
    FOREACH _tbl IN ARRAY _required_tables LOOP
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = _tbl
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '1. Tables',
            _tbl,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'TABLE MISSING' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 2: Critical Columns (001 + 007)
    -- =====================================================================

    -- model_registry.status must be TEXT (not enum)
    SELECT data_type INTO _col_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'model_registry'
      AND column_name = 'status';

    INSERT INTO _verify_results VALUES (
        '2. Columns',
        'model_registry.status',
        CASE
            WHEN _col_type = 'text' THEN 'PASS'
            WHEN _col_type = 'USER-DEFINED' THEN 'FAIL'
            WHEN _col_type IS NULL THEN 'FAIL'
            ELSE 'WARN'
        END,
        CASE
            WHEN _col_type = 'text' THEN 'TEXT (correct)'
            WHEN _col_type = 'USER-DEFINED' THEN 'ENUM — run 007 to convert to TEXT'
            WHEN _col_type IS NULL THEN 'COLUMN MISSING'
            ELSE 'type=' || _col_type
        END
    );

    -- model_registry.pth_url
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND column_name = 'pth_url'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '2. Columns',
        'model_registry.pth_url',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING — run 007' END
    );

    -- pipeline_runs.status
    SELECT data_type INTO _col_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pipeline_runs'
      AND column_name = 'status';

    INSERT INTO _verify_results VALUES (
        '2. Columns',
        'pipeline_runs.status',
        CASE WHEN _col_type IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _col_type IS NOT NULL THEN 'type=' || _col_type ELSE 'COLUMN MISSING' END
    );

    -- pipeline_runs.github_run_id
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'pipeline_runs'
          AND column_name = 'github_run_id'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '2. Columns',
        'pipeline_runs.github_run_id',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING' END
    );

    -- predictions.local_id (used by dedup index)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'predictions'
          AND column_name = 'local_id'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '2. Columns',
        'predictions.local_id',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING' END
    );

    -- =====================================================================
    -- SECTION 3: Functions (002 + 006 + 007)
    -- =====================================================================
    FOREACH _fn IN ARRAY _required_functions LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'public' AND p.proname = _fn
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '3. Functions',
            _fn || '()',
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'FUNCTION MISSING' END
        );
    END LOOP;

    -- sync_model_urls should still exist (002 creates it, 007 drops its TRIGGERS but not the function)
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' AND p.proname = 'sync_model_urls'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '3. Functions',
        'sync_model_urls() [legacy]',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'exists (legacy, triggers dropped by 007)'
             ELSE 'dropped — OK if 007 ran' END
    );

    -- =====================================================================
    -- SECTION 4: Triggers (002 + 007)
    -- =====================================================================

    -- on_auth_user_created (002)
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE t.tgname = 'on_auth_user_created'
          AND n.nspname = 'auth' AND c.relname = 'users'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '4. Triggers',
        'on_auth_user_created ON auth.users',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'TRIGGER MISSING' END
    );

    -- enforce_version_lifecycle_trigger (007 — should exist)
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE t.tgname = 'enforce_version_lifecycle_trigger'
          AND n.nspname = 'public' AND c.relname = 'model_registry'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '4. Triggers',
        'enforce_version_lifecycle_trigger ON model_registry',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'TRIGGER MISSING — run 007' END
    );

    -- sync_model_urls triggers should be GONE (007 drops them)
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE t.tgname IN ('sync_model_urls_trigger', 'sync_model_urls_insert_trigger')
          AND c.relname = 'model_registry'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '4. Triggers',
        'sync_model_urls triggers [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'dropped by 007 (correct)'
             ELSE 'still exists — 007 should have dropped them' END
    );

    -- =====================================================================
    -- SECTION 5: RLS Enabled (003 + 007)
    -- =====================================================================
    FOR _col_check IN
        SELECT c.relname AS tbl, c.relrowsecurity AS rls
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = ANY(_required_tables)
    LOOP
        INSERT INTO _verify_results VALUES (
            '5. RLS Enabled',
            _col_check.tbl,
            CASE WHEN _col_check.rls THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _col_check.rls THEN 'RLS ON' ELSE 'RLS OFF — run 003/007' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 6: RLS Policies (003 + 006 + 007)
    -- =====================================================================
    FOREACH _pol IN ARRAY _required_policies LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public' AND policyname = _pol
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '6. RLS Policies',
            _pol,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'POLICY MISSING' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 7: Indexes (004 + 006 + 007)
    -- =====================================================================
    FOREACH _idx IN ARRAY _required_indexes LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = 'public' AND indexname = _idx
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '7. Indexes',
            _idx,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'INDEX MISSING' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 8: Constraints (001 + 007)
    -- =====================================================================

    -- model_registry: UNIQUE(leaf_type, version) from 007
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND constraint_name = 'model_registry_leaf_version_unique'
          AND constraint_type = 'UNIQUE'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '8. Constraints',
        'model_registry UNIQUE(leaf_type, version)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'CONSTRAINT MISSING — run 007' END
    );

    -- model_registry: old UNIQUE(leaf_type) should be GONE
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND constraint_name = 'model_registry_leaf_type_key'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '8. Constraints',
        'model_registry UNIQUE(leaf_type) [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'dropped by 007 (correct)'
             ELSE 'still exists — 007 should have dropped it' END
    );

    -- model_registry: status CHECK constraint
    SELECT EXISTS (
        SELECT 1 FROM information_schema.check_constraints cc
        JOIN information_schema.constraint_column_usage ccu
          ON cc.constraint_name = ccu.constraint_name
        WHERE ccu.table_schema = 'public'
          AND ccu.table_name = 'model_registry'
          AND ccu.column_name = 'status'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '8. Constraints',
        'model_registry.status CHECK (staging/active/backup)',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'exists' ELSE 'no CHECK — may use enum instead' END
    );

    -- model_benchmarks: UNIQUE(leaf_type, version, format)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'model_benchmarks'
          AND constraint_type = 'UNIQUE'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '8. Constraints',
        'model_benchmarks UNIQUE(leaf_type, version, format)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'CONSTRAINT MISSING' END
    );

    -- =====================================================================
    -- SECTION 9: Storage Buckets (005)
    -- =====================================================================
    FOREACH _bkt IN ARRAY _required_buckets LOOP
        SELECT EXISTS (
            SELECT 1 FROM storage.buckets WHERE id = _bkt
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '9. Storage Buckets',
            _bkt,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'BUCKET MISSING — run 005' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 10: Storage Policies (005)
    -- =====================================================================
    FOR _col_check IN
        SELECT policyname FROM pg_policies WHERE tablename = 'objects' AND schemaname = 'storage'
    LOOP
        NULL; -- just to verify we can read them
    END LOOP;

    -- Check key storage policies
    FOREACH _pol IN ARRAY ARRAY[
        'Public read models', 'Admin upload models',
        'Public read datasets', 'Admin upload datasets',
        'Users upload own images', 'Users read own images', 'Admin read all images'
    ] LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'storage' AND policyname = _pol
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '10. Storage Policies',
            _pol,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'POLICY MISSING — run 005' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 11: Enum cleanup check (007)
    -- =====================================================================
    SELECT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE n.nspname = 'public' AND t.typname = 'model_status'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '11. Cleanup',
        'model_status enum type [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'not present (correct — using TEXT)'
             ELSE 'enum still exists — 007 should have converted to TEXT' END
    );

    -- =====================================================================
    -- SECTION 12: Data integrity spot checks
    -- =====================================================================

    -- All model_registry rows should have status set (not NULL)
    SELECT EXISTS (
        SELECT 1 FROM public.model_registry WHERE status IS NULL
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '12. Data Integrity',
        'model_registry: no NULL status',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'all rows have status'
             ELSE 'some rows have NULL status — re-run 007 migration' END
    );

    -- model_registry status values are valid
    SELECT EXISTS (
        SELECT 1 FROM public.model_registry
        WHERE status NOT IN ('staging', 'active', 'backup')
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '12. Data Integrity',
        'model_registry: valid status values only',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT _exists THEN 'all staging/active/backup'
             ELSE 'invalid status values found!' END
    );

    -- profiles table has at least 1 admin
    SELECT EXISTS (
        SELECT 1 FROM public.profiles WHERE role = 'admin'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '12. Data Integrity',
        'profiles: at least 1 admin exists',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'admin found'
             ELSE 'no admin — set role=admin for your user in profiles table' END
    );

END $$;

-- =====================================================================
-- OUTPUT: Final results
-- =====================================================================
SELECT
    section,
    item,
    CASE status
        WHEN 'PASS' THEN '✅ PASS'
        WHEN 'FAIL' THEN '❌ FAIL'
        WHEN 'WARN' THEN '⚠️ WARN'
    END AS result,
    detail
FROM _verify_results
ORDER BY section, status DESC, item;

-- ── Summary ──
SELECT
    COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
    COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
    COUNT(*) FILTER (WHERE status = 'WARN') AS warnings,
    COUNT(*) AS total,
    CASE
        WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0
        THEN '✅ ALL CHECKS PASSED'
        ELSE '❌ ' || COUNT(*) FILTER (WHERE status = 'FAIL') || ' FAILED — see details above'
    END AS verdict
FROM _verify_results;

DROP TABLE IF EXISTS _verify_results;
