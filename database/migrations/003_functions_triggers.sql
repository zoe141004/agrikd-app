-- =============================================================================
-- AgriKD — 003: Functions & Triggers
-- =============================================================================
-- Source of truth: admin-dashboard/supabase-schema.sql
-- Safe to re-run: CREATE OR REPLACE, DROP TRIGGER IF EXISTS.
-- =============================================================================

-- ── is_admin_role() ─────────────────────────────────────────────────────────
-- SECURITY DEFINER: bypasses RLS to check profiles.role without recursion.
-- Used by ALL RLS policies that gate admin access.
-- NOTE: LANGUAGE sql (not plpgsql) — matches production.

CREATE OR REPLACE FUNCTION public.is_admin_role()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin'
    );
$$ LANGUAGE sql SECURITY DEFINER;

-- ── handle_new_user() ───────────────────────────────────────────────────────
-- Automatically creates a profile row when a new user signs up via Supabase Auth.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, role)
    VALUES (NEW.id, NEW.email, 'user')
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── Backfill profiles for existing auth users ───────────────────────────────
-- Safe to re-run: ON CONFLICT DO NOTHING.

INSERT INTO public.profiles (id, email, role)
SELECT id, email, 'user' FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- ── sync_model_urls() ───────────────────────────────────────────────────────
-- OTA variant routing: Dashboard writes model_url (float16) + model_url_float32.
-- Admin sets active_tflite_variant → trigger routes file_url + sha256_checksum.
-- Flutter reads file_url for OTA download.
-- MUST be BEFORE trigger so it can modify NEW before the row is written.

CREATE OR REPLACE FUNCTION public.sync_model_urls()
RETURNS TRIGGER AS $$
BEGIN
    -- Enforce valid variant values
    IF NEW.active_tflite_variant IS NOT NULL
       AND NEW.active_tflite_variant NOT IN ('float16', 'float32') THEN
        NEW.active_tflite_variant := 'float16';
    END IF;

    -- Route file_url based on admin's variant choice
    IF COALESCE(NEW.active_tflite_variant, 'float16') = 'float32'
       AND NEW.model_url_float32 IS NOT NULL THEN
        NEW.file_url := NEW.model_url_float32;
        -- Route sha256_checksum from float32 variant if available
        IF NEW.sha256_float32 IS NOT NULL THEN
            NEW.sha256_checksum := NEW.sha256_float32;
        END IF;
    ELSIF NEW.model_url IS NOT NULL THEN
        NEW.file_url := NEW.model_url;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- BEFORE triggers on model_registry (INSERT + UPDATE)
DROP TRIGGER IF EXISTS sync_model_urls_trigger ON public.model_registry;
CREATE TRIGGER sync_model_urls_trigger
    BEFORE UPDATE ON public.model_registry
    FOR EACH ROW EXECUTE FUNCTION public.sync_model_urls();

DROP TRIGGER IF EXISTS sync_model_urls_insert_trigger ON public.model_registry;
CREATE TRIGGER sync_model_urls_insert_trigger
    BEFORE INSERT ON public.model_registry
    FOR EACH ROW EXECUTE FUNCTION public.sync_model_urls();
