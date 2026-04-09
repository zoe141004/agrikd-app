-- Migration 010: Fix enforce_version_lifecycle
-- 1. Remove FOR UPDATE from COUNT(*) aggregate (PostgreSQL disallows it)
-- 2. Demote by lowest version instead of oldest updated_at

CREATE OR REPLACE FUNCTION public.enforce_version_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    active_count INT;
    lowest_version_id UUID;
BEGIN
    -- Guard against recursive trigger calls
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

    -- Backward compat: sync file_url = model_url for old Flutter clients
    IF NEW.model_url IS NOT NULL THEN
        NEW.file_url := NEW.model_url;
    END IF;

    -- When status transitions to 'active', enforce max 2 active per leaf_type
    IF NEW.status = 'active'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'active')
    THEN
        SELECT COUNT(*) INTO active_count
        FROM public.model_registry
        WHERE leaf_type = NEW.leaf_type
          AND status = 'active'
          AND id IS DISTINCT FROM NEW.id;

        IF active_count >= 2 THEN
            -- Demote the lowest version to 'backup'
            -- Use semantic version comparison (int array) instead of text sort
            SELECT id INTO lowest_version_id
            FROM public.model_registry
            WHERE leaf_type = NEW.leaf_type
              AND status = 'active'
              AND id IS DISTINCT FROM NEW.id
            ORDER BY string_to_array(version, '.')::int[] ASC
            LIMIT 1
            FOR UPDATE;

            UPDATE public.model_registry
            SET status = 'backup', updated_at = now()
            WHERE id = lowest_version_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;
