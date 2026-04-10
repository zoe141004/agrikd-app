-- =============================================================================
-- Migration 015: audit_log table cleanup
-- =============================================================================
-- The audit_log table may have been created manually with a different schema:
--   id BIGINT, actor_email TEXT, entity_id BIGINT
-- Expected (per 001_tables.sql):
--   id UUID, user_id UUID, entity_id TEXT
--
-- This migration safely converts the table to the correct schema while
-- preserving existing data.
-- =============================================================================

-- ── Step 1: Rename old table ─────────────────────────────────────────────────
DO $$
BEGIN
    -- Only proceed if audit_log has the legacy bigint id column
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_log'
          AND column_name = 'id'
          AND data_type = 'bigint'
    ) THEN
        RAISE NOTICE '015: audit_log has legacy bigint schema — starting cleanup';

        -- Drop policies on old table (will recreate on new table)
        DROP POLICY IF EXISTS "Admins read audit log" ON public.audit_log;
        DROP POLICY IF EXISTS "Admins insert audit log" ON public.audit_log;

        -- Drop indexes on old table
        DROP INDEX IF EXISTS public.idx_audit_log_created_at;
        DROP INDEX IF EXISTS public.idx_audit_log_user_id;

        -- Rename old table
        ALTER TABLE public.audit_log RENAME TO audit_log_legacy;

        -- Create new table with correct schema
        CREATE TABLE public.audit_log (
            id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id     UUID REFERENCES auth.users(id),
            action      TEXT NOT NULL,
            entity_type TEXT,
            entity_id   TEXT,
            details     JSONB,
            created_at  TIMESTAMPTZ DEFAULT now()
        );

        -- Migrate data from legacy table
        INSERT INTO public.audit_log (user_id, action, entity_type, entity_id, details, created_at)
        SELECT
            user_id,                            -- may be NULL for old rows
            action,
            entity_type,
            entity_id::TEXT,                    -- cast bigint → text
            details,
            created_at
        FROM public.audit_log_legacy;

        -- Enable RLS
        ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

        -- Recreate policies
        CREATE POLICY "Admins read audit log" ON public.audit_log
            FOR SELECT USING (public.is_admin_role());
        CREATE POLICY "Admins insert audit log" ON public.audit_log
            FOR INSERT WITH CHECK (public.is_admin_role());

        -- Recreate indexes
        CREATE INDEX idx_audit_log_created_at ON public.audit_log (created_at);
        CREATE INDEX idx_audit_log_user_id ON public.audit_log (user_id);

        -- Drop legacy table
        DROP TABLE public.audit_log_legacy;

        RAISE NOTICE '015: audit_log cleanup complete — migrated to UUID schema';
    ELSE
        RAISE NOTICE '015: audit_log already has correct schema — skipping';
    END IF;
END;
$$;
