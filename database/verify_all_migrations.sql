-- =============================================================================
-- AgriKD — Comprehensive Migration Verification (001–016)
-- =============================================================================
-- Run in Supabase SQL Editor AFTER executing all 16 migrations.
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
        'model_benchmarks', 'model_versions', 'model_reports', 'pipeline_runs',
        'dvc_operations', 'devices', 'provisioning_tokens', 'model_engines'
    ];

    -- ── Helper: check column ──
    _col_check RECORD;

    -- ── Helper: check function ──
    _fn TEXT;
    _required_functions TEXT[] := ARRAY[
        'is_admin_role', 'handle_new_user', 'enforce_version_lifecycle',
        'get_dashboard_stats', 'get_disease_distribution', 'get_leaf_type_options',
        'claim_provisioning_token', 'update_device_config', 'increment_config_version',
        'get_latest_onnx_url', 'get_engine_for_hardware'
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
        'idx_pipeline_runs_leaf_version',
        'idx_dvc_operations_leaf_type', 'idx_dvc_operations_active',
        'idx_devices_hw_id', 'idx_devices_token', 'idx_devices_user',
        'idx_devices_status', 'idx_predictions_device', 'idx_prov_tokens_unused',
        'idx_model_engines_lookup', 'idx_audit_log_user_id'
    ];

    -- ── Helper: check RLS policy ──
    _pol TEXT;
    _required_policies TEXT[] := ARRAY[
        -- predictions (4 from 003 + 1 from 012)
        'Users read own predictions', 'Users insert own predictions',
        'Admins update predictions', 'Admins delete predictions',
        'Device insert predictions',
        -- model_registry (4)
        'Anyone can read models', 'Admins insert models',
        'Admins update models', 'Admins delete models',
        -- profiles (3: 003 + 014)
        'Users read own profile', 'Admins manage profiles',
        'Users update own profile',
        -- audit_log (2)
        'Admins read audit log', 'Admins insert audit log',
        -- model_benchmarks (4)
        'Anyone can read benchmarks', 'Admins insert benchmarks',
        'Admins update benchmarks', 'Admins delete benchmarks',
        -- model_versions (2)
        'Anyone can read model versions', 'Admins manage model versions',
        -- model_reports (3: 006 + 014)
        'Users insert own reports', 'Admins read reports',
        'Users read own reports',
        -- pipeline_runs (2)
        'Anyone can view pipeline runs', 'Admins manage pipeline runs',
        -- dvc_operations (2 from 011)
        'Anyone can view dvc operations', 'Admins manage dvc operations',
        -- devices (7 from 012)
        'Admin manage all devices', 'Users read own devices',
        'Users update own device config', 'Device self-read',
        'Device update reported', 'Device self-register',
        -- provisioning_tokens (3 from 012)
        'Admin manage tokens', 'Anon read unused tokens', 'Anon claim token',
        -- model_engines (4 from 013)
        'Anyone can read engines', 'Service role manages engines',
        'Service role updates engines', 'Admins delete engines'
    ];

    -- ── Helper: check storage bucket ──
    _bkt TEXT;
    _required_buckets TEXT[] := ARRAY['models', 'datasets', 'prediction-images'];

    -- ── Temp vars ──
    _exists BOOLEAN;
    _col_type TEXT;
    _text_val TEXT;
    _int_val INT;

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
            '01. Tables',
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
        '02. Columns',
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
        '02. Columns',
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
        '02. Columns',
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
        '02. Columns',
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
        '02. Columns',
        'predictions.local_id',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING' END
    );

    -- predictions.device_id (012 — links prediction to device)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'predictions'
          AND column_name = 'device_id'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '02. Columns',
        'predictions.device_id',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING — run 012' END
    );

    -- model_registry.onnx_url (013)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND column_name = 'onnx_url'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '02. Columns',
        'model_registry.onnx_url',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING — run 013' END
    );

    -- model_registry.onnx_sha256 (013)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'model_registry'
          AND column_name = 'onnx_sha256'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '02. Columns',
        'model_registry.onnx_sha256',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING — run 013' END
    );

    -- devices.device_token (012)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'devices'
          AND column_name = 'device_token'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '02. Columns',
        'devices.device_token',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'COLUMN MISSING — run 012' END
    );

    -- =====================================================================
    -- SECTION 3: Functions (002 + 006 + 007 + 008)
    -- =====================================================================
    FOREACH _fn IN ARRAY _required_functions LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'public' AND p.proname = _fn
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '03. Functions',
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
        '03. Functions',
        'sync_model_urls() [legacy]',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'exists (legacy, triggers dropped by 007)'
             ELSE 'dropped — OK if 007 ran' END
    );

    -- =====================================================================
    -- SECTION 4: SECURITY DEFINER + SET search_path (009)
    -- =====================================================================

    -- All SECURITY DEFINER functions must have SET search_path (009)
    FOR _col_check IN
        SELECT p.proname,
               p.prosecdef AS is_secdef,
               p.proconfig AS config
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.proname IN (
              'is_admin_role', 'handle_new_user', 'sync_model_urls',
              'enforce_version_lifecycle',
              'get_dashboard_stats', 'get_disease_distribution', 'get_leaf_type_options',
              'claim_provisioning_token', 'update_device_config'
          )
    LOOP
        IF _col_check.is_secdef THEN
            IF _col_check.config IS NOT NULL
               AND array_to_string(_col_check.config, ',') LIKE '%search_path%' THEN
                INSERT INTO _verify_results VALUES (
                    '04. Security (009)',
                    _col_check.proname || '() SET search_path',
                    'PASS',
                    'SECURITY DEFINER + SET search_path'
                );
            ELSE
                INSERT INTO _verify_results VALUES (
                    '04. Security (009)',
                    _col_check.proname || '() SET search_path',
                    'FAIL',
                    'SECURITY DEFINER but MISSING SET search_path — run 009'
                );
            END IF;
        ELSE
            INSERT INTO _verify_results VALUES (
                '04. Security (009)',
                _col_check.proname || '() SET search_path',
                'WARN',
                'not SECURITY DEFINER — search_path not applicable'
            );
        END IF;
    END LOOP;

    -- =====================================================================
    -- SECTION 5: Triggers (002 + 007)
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
        '05. Triggers',
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
        '05. Triggers',
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
        '05. Triggers',
        'sync_model_urls triggers [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'dropped by 007 (correct)'
             ELSE 'still exists — 007 should have dropped them' END
    );

    -- trg_config_version (012 — auto-increment config on desired_config change)
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE t.tgname = 'trg_config_version'
          AND n.nspname = 'public' AND c.relname = 'devices'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '05. Triggers',
        'trg_config_version ON devices',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'TRIGGER MISSING — run 012' END
    );

    -- =====================================================================
    -- SECTION 6: RLS Enabled (003 + 007)
    -- =====================================================================
    FOR _col_check IN
        SELECT c.relname AS tbl, c.relrowsecurity AS rls
        FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public'
          AND c.relname = ANY(_required_tables)
    LOOP
        INSERT INTO _verify_results VALUES (
            '06. RLS Enabled',
            _col_check.tbl,
            CASE WHEN _col_check.rls THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _col_check.rls THEN 'RLS ON' ELSE 'RLS OFF — run 003/007' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 7: RLS Policies (003 + 006 + 007)
    -- =====================================================================
    FOREACH _pol IN ARRAY _required_policies LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public' AND policyname = _pol
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '07. RLS Policies',
            _pol,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'POLICY MISSING' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 8: Indexes (004 + 006 + 007)
    -- =====================================================================
    FOREACH _idx IN ARRAY _required_indexes LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = 'public' AND indexname = _idx
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '08. Indexes',
            _idx,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'INDEX MISSING' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 9: Constraints (001 + 007 + 008 + 009)
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
        '09. Constraints',
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
        '09. Constraints',
        'model_registry UNIQUE(leaf_type) [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'dropped by 007 (correct)'
             ELSE 'still exists — 007 should have dropped it' END
    );

    -- model_registry: status CHECK constraint
    SELECT EXISTS (
        SELECT 1 FROM pg_constraint con
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
        WHERE con.conrelid = 'public.model_registry'::regclass
          AND con.contype = 'c'
          AND att.attname = 'status'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '09. Constraints',
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
        '09. Constraints',
        'model_benchmarks UNIQUE(leaf_type, version, format)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'CONSTRAINT MISSING' END
    );

    -- model_benchmarks: format CHECK constraint (008)
    SELECT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.model_benchmarks'::regclass
          AND contype = 'c'
          AND conname = 'model_benchmarks_format_check'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '09. Constraints (008)',
        'model_benchmarks.format CHECK (pytorch/onnx/tflite_float16)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'CONSTRAINT MISSING — run 008' END
    );

    -- Verify no ghost check constraints on model_benchmarks.format
    SELECT COUNT(*) INTO _int_val
    FROM pg_constraint con
    JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
    WHERE con.conrelid = 'public.model_benchmarks'::regclass
      AND con.contype = 'c'
      AND att.attname = 'format';

    INSERT INTO _verify_results VALUES (
        '09. Constraints (008)',
        'model_benchmarks.format check constraint count',
        CASE WHEN _int_val = 1 THEN 'PASS'
             WHEN _int_val = 0 THEN 'FAIL'
             ELSE 'FAIL' END,
        CASE WHEN _int_val = 1 THEN 'exactly 1 (correct)'
             WHEN _int_val = 0 THEN 'none — run 008'
             ELSE _int_val || ' constraints! Ghost constraints from partial runs — re-run 008' END
    );

    -- model_registry.updated_at DEFAULT (009)
    SELECT column_default INTO _text_val
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'model_registry'
      AND column_name = 'updated_at';

    INSERT INTO _verify_results VALUES (
        '09. Constraints (009)',
        'model_registry.updated_at DEFAULT now()',
        CASE WHEN _text_val IS NOT NULL AND _text_val LIKE '%now()%' THEN 'PASS'
             ELSE 'FAIL' END,
        CASE WHEN _text_val IS NOT NULL AND _text_val LIKE '%now()%' THEN 'DEFAULT=' || _text_val
             WHEN _text_val IS NULL THEN 'no DEFAULT — run 009'
             ELSE 'DEFAULT=' || _text_val || ' (unexpected)' END
    );

    -- model_engines: UNIQUE(leaf_type, version, hardware_tag) from 013
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name = 'model_engines'
          AND constraint_name = 'uq_model_engines_hw'
          AND constraint_type = 'UNIQUE'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '09. Constraints (013)',
        'model_engines UNIQUE(leaf_type, version, hardware_tag)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'CONSTRAINT MISSING — run 013' END
    );

    -- devices: UNIQUE(hw_id) from 012
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
        WHERE tc.table_schema = 'public'
          AND tc.table_name = 'devices'
          AND tc.constraint_type = 'UNIQUE'
          AND kcu.column_name = 'hw_id'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '09. Constraints (012)',
        'devices UNIQUE(hw_id)',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'UNIQUE MISSING — run 012' END
    );

    -- =====================================================================
    -- SECTION 10: Storage Buckets (005)
    -- =====================================================================
    FOREACH _bkt IN ARRAY _required_buckets LOOP
        SELECT EXISTS (
            SELECT 1 FROM storage.buckets WHERE id = _bkt
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '10. Storage Buckets',
            _bkt,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'BUCKET MISSING — run 005' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 11: Storage Policies (005)
    -- =====================================================================
    FOREACH _pol IN ARRAY ARRAY[
        'Public read models', 'Admin upload models',
        'Admin update models', 'Admin delete models',
        'Public read datasets', 'Admin upload datasets',
        'Admin update datasets', 'Admin delete datasets',
        'Users upload own images', 'Users read own images',
        'Users delete own images',
        'Admin read all images', 'Admin delete all images'
    ] LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'storage' AND policyname = _pol
        ) INTO _exists;

        INSERT INTO _verify_results VALUES (
            '11. Storage Policies',
            _pol,
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN _exists THEN 'exists' ELSE 'POLICY MISSING — run 005' END
        );
    END LOOP;

    -- =====================================================================
    -- SECTION 12: Enum cleanup check (007)
    -- =====================================================================
    SELECT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE n.nspname = 'public' AND t.typname = 'model_status'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '12. Cleanup',
        'model_status enum type [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'not present (correct — using TEXT)'
             ELSE 'enum still exists — 007 should have converted to TEXT' END
    );

    -- =====================================================================
    -- SECTION 13: Data integrity checks
    -- =====================================================================

    -- All model_registry rows should have status set (not NULL)
    SELECT EXISTS (
        SELECT 1 FROM public.model_registry WHERE status IS NULL
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '13. Data Integrity',
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
        '13. Data Integrity',
        'model_registry: valid status values only',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT _exists THEN 'all staging/active/backup'
             ELSE 'invalid status values found!' END
    );

    -- model_benchmarks: no invalid format values (008)
    SELECT EXISTS (
        SELECT 1 FROM public.model_benchmarks
        WHERE format NOT IN ('pytorch', 'onnx', 'tflite_float16')
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '13. Data Integrity (008)',
        'model_benchmarks: valid format values only',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT _exists THEN 'all pytorch/onnx/tflite_float16'
             ELSE 'invalid format values found! Re-run 008' END
    );

    -- model_benchmarks: row count per format (informational)
    SELECT string_agg(format || '=' || cnt::TEXT, ', ' ORDER BY format) INTO _text_val
    FROM (
        SELECT format, COUNT(*) AS cnt
        FROM public.model_benchmarks
        GROUP BY format
    ) sub;

    INSERT INTO _verify_results VALUES (
        '13. Data Integrity (008)',
        'model_benchmarks: format distribution',
        'PASS',
        COALESCE(_text_val, 'empty table')
    );

    -- profiles table has at least 1 admin
    SELECT EXISTS (
        SELECT 1 FROM public.profiles WHERE role = 'admin'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '13. Data Integrity',
        'profiles: at least 1 admin exists',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'admin found'
             ELSE 'no admin — set role=admin for your user in profiles table' END
    );

    -- =====================================================================
    -- SECTION 14: Realtime publication (008 + 011)
    -- =====================================================================
    SELECT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND tablename = 'pipeline_runs'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '14. Realtime',
        'pipeline_runs in supabase_realtime publication',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'enabled'
             ELSE 'not in publication — add manually in Dashboard → Database → Replication' END
    );

    SELECT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND tablename = 'dvc_operations'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '14. Realtime',
        'dvc_operations in supabase_realtime publication',
        CASE WHEN _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _exists THEN 'enabled'
             ELSE 'not in publication — add manually in Dashboard → Database → Replication' END
    );

    -- =====================================================================
    -- SECTION 15: Migration 014 — Admin guards on RPCs
    -- =====================================================================

    -- Check that get_dashboard_stats uses PL/pgSQL (not SQL) — indicates admin guard
    SELECT l.lanname INTO _text_val
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_language l ON p.prolang = l.oid
    WHERE n.nspname = 'public' AND p.proname = 'get_dashboard_stats';

    INSERT INTO _verify_results VALUES (
        '15. Admin Guards (014)',
        'get_dashboard_stats() language',
        CASE WHEN _text_val = 'plpgsql' THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _text_val = 'plpgsql' THEN 'plpgsql (has admin guard)'
             WHEN _text_val = 'sql' THEN 'sql — missing admin guard! Run 014'
             ELSE COALESCE(_text_val, 'function not found') END
    );

    -- Check that get_disease_distribution uses PL/pgSQL — indicates admin guard
    SELECT l.lanname INTO _text_val
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_language l ON p.prolang = l.oid
    WHERE n.nspname = 'public' AND p.proname = 'get_disease_distribution';

    INSERT INTO _verify_results VALUES (
        '15. Admin Guards (014)',
        'get_disease_distribution() language',
        CASE WHEN _text_val = 'plpgsql' THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _text_val = 'plpgsql' THEN 'plpgsql (has admin guard)'
             WHEN _text_val = 'sql' THEN 'sql — missing admin guard! Run 014'
             ELSE COALESCE(_text_val, 'function not found') END
    );

    -- Check that get_leaf_type_options uses PL/pgSQL — indicates admin guard
    SELECT l.lanname INTO _text_val
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    JOIN pg_language l ON p.prolang = l.oid
    WHERE n.nspname = 'public' AND p.proname = 'get_leaf_type_options';

    INSERT INTO _verify_results VALUES (
        '15. Admin Guards (014)',
        'get_leaf_type_options() language',
        CASE WHEN _text_val = 'plpgsql' THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN _text_val = 'plpgsql' THEN 'plpgsql (has admin guard)'
             WHEN _text_val = 'sql' THEN 'sql — missing admin guard! Run 014'
             ELSE COALESCE(_text_val, 'function not found') END
    );

    -- FK constraint from provisioning_tokens to devices (012)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_prov_device'
          AND table_schema = 'public'
          AND table_name = 'provisioning_tokens'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '15. Constraints (012)',
        'fk_prov_device on provisioning_tokens',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'FK MISSING — run 012' END
    );

    -- FK constraint from model_engines to model_registry (013)
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_engines_registry'
          AND table_schema = 'public'
          AND table_name = 'model_engines'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '15. Constraints (013)',
        'fk_model_engines_registry on model_engines',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'FK MISSING — run 013' END
    );

    -- =====================================================================
    -- SECTION 16: Migration 015 — audit_log schema cleanup
    -- =====================================================================

    -- audit_log.id must be UUID (015 converts from BIGINT)
    SELECT data_type INTO _col_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'audit_log'
      AND column_name = 'id';

    INSERT INTO _verify_results VALUES (
        '16. Migration 015',
        'audit_log.id type = uuid',
        CASE
            WHEN _col_type = 'uuid' THEN 'PASS'
            WHEN _col_type = 'bigint' THEN 'FAIL'
            WHEN _col_type IS NULL THEN 'FAIL'
            ELSE 'WARN'
        END,
        CASE
            WHEN _col_type = 'uuid' THEN 'uuid (correct)'
            WHEN _col_type = 'bigint' THEN 'BIGINT — run 015 to convert to UUID'
            WHEN _col_type IS NULL THEN 'COLUMN MISSING'
            ELSE 'type=' || _col_type
        END
    );

    -- audit_log.entity_id must be TEXT (015 casts bigint → text)
    SELECT data_type INTO _col_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'audit_log'
      AND column_name = 'entity_id';

    INSERT INTO _verify_results VALUES (
        '16. Migration 015',
        'audit_log.entity_id type = text',
        CASE
            WHEN _col_type = 'text' THEN 'PASS'
            WHEN _col_type = 'bigint' THEN 'FAIL'
            WHEN _col_type IS NULL THEN 'FAIL'
            ELSE 'WARN'
        END,
        CASE
            WHEN _col_type = 'text' THEN 'text (correct)'
            WHEN _col_type = 'bigint' THEN 'BIGINT — run 015 to convert to TEXT'
            WHEN _col_type IS NULL THEN 'COLUMN MISSING'
            ELSE 'type=' || _col_type
        END
    );

    -- audit_log_legacy table should NOT exist after 015 cleanup
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'audit_log_legacy'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '16. Migration 015',
        'audit_log_legacy table [should be dropped]',
        CASE WHEN NOT _exists THEN 'PASS' ELSE 'WARN' END,
        CASE WHEN NOT _exists THEN 'not present (correct — cleanup complete)'
             ELSE 'still exists — 015 cleanup may be incomplete' END
    );

    -- =====================================================================
    -- SECTION 17: Migration 016 — composite FK constraints
    -- =====================================================================

    -- fk_model_benchmarks_leaf_version
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_benchmarks_leaf_version'
          AND table_schema = 'public'
          AND table_name = 'model_benchmarks'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '17. Migration 016',
        'fk_model_benchmarks_leaf_version on model_benchmarks',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'FK MISSING — run 016' END
    );

    -- fk_model_versions_leaf_version
    SELECT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_model_versions_leaf_version'
          AND table_schema = 'public'
          AND table_name = 'model_versions'
    ) INTO _exists;

    INSERT INTO _verify_results VALUES (
        '17. Migration 016',
        'fk_model_versions_leaf_version on model_versions',
        CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _exists THEN 'exists' ELSE 'FK MISSING — run 016' END
    );

END $$;

-- =====================================================================
-- OUTPUT 1: FAILURES ONLY (most important — check this first)
-- =====================================================================
SELECT
    '❌ FAIL' AS result,
    section,
    item,
    detail
FROM _verify_results
WHERE status = 'FAIL'
ORDER BY section, item;

-- =====================================================================
-- OUTPUT 2: Full results
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

-- =====================================================================
-- OUTPUT 3: Summary
-- =====================================================================
SELECT
    COUNT(*) FILTER (WHERE status = 'PASS') AS passed,
    COUNT(*) FILTER (WHERE status = 'FAIL') AS failed,
    COUNT(*) FILTER (WHERE status = 'WARN') AS warnings,
    COUNT(*) AS total,
    CASE
        WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0
        THEN '✅ ALL CHECKS PASSED (migrations 001–016)'
        ELSE '❌ ' || COUNT(*) FILTER (WHERE status = 'FAIL') || ' FAILED — see details above'
    END AS verdict
FROM _verify_results;

DROP TABLE IF EXISTS _verify_results;
