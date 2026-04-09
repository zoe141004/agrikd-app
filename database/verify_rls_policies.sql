-- =============================================================================
-- AgriKD — RLS & Security Verification Script (IaC Audit)
-- =============================================================================
-- Run in Supabase SQL Editor to verify all Row Level Security policies,
-- triggers, functions, storage policies, and indexes are correctly configured.
--
-- Usage: Paste into SQL Editor → Run → Check Messages/Notices tab for results.
-- =============================================================================

DO $$
DECLARE
    _tbl        TEXT;
    _rls_on     BOOLEAN;
    _policy     RECORD;
    _found      BOOLEAN;
    _count      INT;
    _idx        RECORD;
    _pass_count INT := 0;
    _fail_count INT := 0;

    -- Tables that MUST have RLS enabled
    _required_tables TEXT[] := ARRAY[
        'predictions',
        'model_registry',
        'profiles',
        'audit_log',
        'model_benchmarks',
        'model_versions',
        'pipeline_runs',
        'devices',
        'provisioning_tokens',
        'dvc_operations',
        'model_engines'
    ];
BEGIN
    RAISE NOTICE '===================================================================';
    RAISE NOTICE ' AgriKD — RLS & Security Audit';
    RAISE NOTICE ' Run at: %', NOW();
    RAISE NOTICE '===================================================================';
    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 1: RLS enabled on all required tables
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 1. RLS STATUS ON TABLES ──────────────────────────────────────';

    FOREACH _tbl IN ARRAY _required_tables
    LOOP
        SELECT relrowsecurity
          INTO _rls_on
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname = _tbl;

        IF NOT FOUND THEN
            RAISE NOTICE '[FAIL] Table "%" does not exist.', _tbl;
            _fail_count := _fail_count + 1;
        ELSIF _rls_on THEN
            RAISE NOTICE '[PASS] RLS ENABLED on "%".', _tbl;
            _pass_count := _pass_count + 1;
        ELSE
            RAISE NOTICE '[FAIL] RLS DISABLED on "%".', _tbl;
            _fail_count := _fail_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 2: List all policies per table
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 2. POLICIES PER TABLE ────────────────────────────────────────';

    FOREACH _tbl IN ARRAY _required_tables
    LOOP
        _count := 0;
        RAISE NOTICE '';
        RAISE NOTICE '  Table: %', _tbl;

        FOR _policy IN
            SELECT
                pol.polname AS policy_name,
                CASE pol.polcmd
                    WHEN 'r' THEN 'SELECT'
                    WHEN 'a' THEN 'INSERT'
                    WHEN 'w' THEN 'UPDATE'
                    WHEN 'd' THEN 'DELETE'
                    WHEN '*' THEN 'ALL'
                END AS cmd
              FROM pg_policy pol
              JOIN pg_class c ON c.oid = pol.polrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relname = _tbl
             ORDER BY pol.polname
        LOOP
            RAISE NOTICE '    [%] %', _policy.cmd, _policy.policy_name;
            _count := _count + 1;
        END LOOP;

        IF _count = 0 THEN
            RAISE NOTICE '  [FAIL] No policies on "%".', _tbl;
            _fail_count := _fail_count + 1;
        ELSE
            RAISE NOTICE '  [PASS] % policies on "%".', _count, _tbl;
            _pass_count := _pass_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 3: Verify is_admin_role() function
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 3. is_admin_role() FUNCTION ──────────────────────────────────';

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'is_admin_role'
    ) INTO _found;

    IF NOT _found THEN
        RAISE NOTICE '[FAIL] is_admin_role() does NOT exist.';
        _fail_count := _fail_count + 1;
    ELSE
        RAISE NOTICE '[PASS] is_admin_role() exists.';
        _pass_count := _pass_count + 1;

        -- Check SECURITY DEFINER
        SELECT p.prosecdef INTO _found
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'is_admin_role';

        IF _found THEN
            RAISE NOTICE '[PASS] is_admin_role() is SECURITY DEFINER.';
            _pass_count := _pass_count + 1;
        ELSE
            RAISE NOTICE '[FAIL] is_admin_role() is NOT SECURITY DEFINER.';
            _fail_count := _fail_count + 1;
        END IF;
    END IF;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 4: Verify handle_new_user() trigger on auth.users
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 4. handle_new_user() TRIGGER ─────────────────────────────────';

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname = 'handle_new_user' AND n.nspname = 'public'
    ) INTO _found;

    IF _found THEN
        RAISE NOTICE '[PASS] handle_new_user() function exists.';
        _pass_count := _pass_count + 1;
    ELSE
        RAISE NOTICE '[FAIL] handle_new_user() function NOT found.';
        _fail_count := _fail_count + 1;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE n.nspname = 'auth' AND c.relname = 'users'
          AND p.proname = 'handle_new_user' AND NOT t.tgisinternal
    ) INTO _found;

    IF _found THEN
        RAISE NOTICE '[PASS] Trigger on auth.users → handle_new_user() exists.';
        _pass_count := _pass_count + 1;
    ELSE
        RAISE NOTICE '[FAIL] No trigger on auth.users → handle_new_user().';
        _fail_count := _fail_count + 1;
    END IF;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 5: Verify enforce_version_lifecycle() trigger on model_registry
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 5. enforce_version_lifecycle() TRIGGER ──────────────────────────';

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname = 'enforce_version_lifecycle' AND n.nspname = 'public'
    ) INTO _found;

    IF _found THEN
        RAISE NOTICE '[PASS] enforce_version_lifecycle() function exists.';
        _pass_count := _pass_count + 1;
    ELSE
        RAISE NOTICE '[FAIL] enforce_version_lifecycle() function NOT found.';
        _fail_count := _fail_count + 1;
    END IF;

    -- Check BEFORE INSERT OR UPDATE trigger
    SELECT COUNT(*) INTO _count
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE n.nspname = 'public' AND c.relname = 'model_registry'
       AND p.proname = 'enforce_version_lifecycle' AND NOT t.tgisinternal;

    IF _count >= 1 THEN
        RAISE NOTICE '[PASS] % enforce_version_lifecycle trigger(s) on model_registry.', _count;
        _pass_count := _pass_count + 1;
    ELSE
        RAISE NOTICE '[FAIL] No enforce_version_lifecycle triggers on model_registry.';
        _fail_count := _fail_count + 1;
    END IF;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 6: Storage bucket policies
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 6. STORAGE BUCKETS & POLICIES ────────────────────────────────';

    -- Check each required bucket
    FOREACH _tbl IN ARRAY ARRAY['models', 'datasets', 'prediction-images']
    LOOP
        SELECT EXISTS (
            SELECT 1 FROM storage.buckets WHERE name = _tbl
        ) INTO _found;

        IF _found THEN
            RAISE NOTICE '[PASS] Bucket "%" exists.', _tbl;
            _pass_count := _pass_count + 1;
        ELSE
            RAISE NOTICE '[FAIL] Bucket "%" NOT found.', _tbl;
            _fail_count := _fail_count + 1;
        END IF;
    END LOOP;

    -- Count storage.objects policies
    SELECT COUNT(*) INTO _count
      FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'storage' AND c.relname = 'objects';

    IF _count > 0 THEN
        RAISE NOTICE '[PASS] storage.objects has % policies.', _count;
        _pass_count := _pass_count + 1;
    ELSE
        RAISE NOTICE '[FAIL] storage.objects has NO policies.';
        _fail_count := _fail_count + 1;
    END IF;

    -- List storage policies
    RAISE NOTICE '';
    RAISE NOTICE '  All storage.objects policies:';
    FOR _policy IN
        SELECT pol.polname AS policy_name,
               CASE pol.polcmd
                   WHEN 'r' THEN 'SELECT'
                   WHEN 'a' THEN 'INSERT'
                   WHEN 'w' THEN 'UPDATE'
                   WHEN 'd' THEN 'DELETE'
                   WHEN '*' THEN 'ALL'
               END AS cmd
          FROM pg_policy pol
          JOIN pg_class c ON c.oid = pol.polrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'storage' AND c.relname = 'objects'
         ORDER BY pol.polname
    LOOP
        RAISE NOTICE '    [%] %', _policy.cmd, _policy.policy_name;
    END LOOP;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SECTION 7: Index verification
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '── 7. INDEX VERIFICATION ────────────────────────────────────────';

    -- Check critical indexes
    FOREACH _tbl IN ARRAY ARRAY[
        'idx_predictions_user_id',
        'idx_predictions_leaf_type',
        'idx_predictions_created_at',
        'idx_predictions_confidence',
        'idx_audit_log_created_at',
        'idx_model_benchmarks_leaf_type',
        'idx_model_versions_leaf_type',
        'idx_devices_hw_id',
        'idx_devices_token',
        'idx_devices_user',
        'idx_devices_status',
        'idx_predictions_device',
        'idx_prov_tokens_unused'
    ]
    LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = 'public' AND indexname = _tbl
        ) INTO _found;

        IF _found THEN
            RAISE NOTICE '[PASS] Index "%" exists.', _tbl;
            _pass_count := _pass_count + 1;
        ELSE
            RAISE NOTICE '[FAIL] Index "%" NOT found.', _tbl;
            _fail_count := _fail_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '';

    -- ═════════════════════════════════════════════════════════════════
    -- SUMMARY
    -- ═════════════════════════════════════════════════════════════════
    RAISE NOTICE '===================================================================';
    RAISE NOTICE ' SUMMARY';
    RAISE NOTICE '===================================================================';
    RAISE NOTICE '  Total PASS : %', _pass_count;
    RAISE NOTICE '  Total FAIL : %', _fail_count;
    RAISE NOTICE '';

    IF _fail_count = 0 THEN
        RAISE NOTICE '  *** ALL CHECKS PASSED ***';
    ELSE
        RAISE NOTICE '  *** % CHECK(S) FAILED — review output above ***', _fail_count;
    END IF;

    RAISE NOTICE '===================================================================';
END
$$;
