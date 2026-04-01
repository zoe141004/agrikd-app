-- =============================================================================
-- AgriKD — 003: Functions & Triggers
-- =============================================================================

-- ── is_admin_role() ───────────────────────────────────────────────────────────
-- SECURITY DEFINER: runs with elevated privileges to check user role.
-- Used by RLS policies across all admin-protected tables.
CREATE OR REPLACE FUNCTION public.is_admin_role()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin'
    );
END;
$$;

-- ── handle_new_user() ─────────────────────────────────────────────────────────
-- Automatically creates a profile row when a new user signs up.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, role, is_active)
    VALUES (NEW.id, NEW.email, 'user', true)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- Trigger on auth.users
DROP TRIGGER IF EXISTS handle_new_user ON auth.users;
CREATE TRIGGER handle_new_user
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── sync_model_urls() ─────────────────────────────────────────────────────────
-- Automatically generates download URLs when model files are uploaded.
-- TODO: Export actual function body from Supabase Dashboard
--       (Database → Functions → sync_model_urls → Definition)
CREATE OR REPLACE FUNCTION public.sync_model_urls()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- TODO: paste your actual sync_model_urls() logic here
    -- This function typically constructs a public download URL from
    -- the storage bucket path and updates model_registry.download_url
    RETURN NEW;
END;
$$;

-- Triggers on model_registry (INSERT + UPDATE)
DROP TRIGGER IF EXISTS sync_model_urls_insert ON public.model_registry;
CREATE TRIGGER sync_model_urls_insert
    AFTER INSERT ON public.model_registry
    FOR EACH ROW EXECUTE FUNCTION public.sync_model_urls();

DROP TRIGGER IF EXISTS sync_model_urls_update ON public.model_registry;
CREATE TRIGGER sync_model_urls_update
    AFTER UPDATE ON public.model_registry
    FOR EACH ROW EXECUTE FUNCTION public.sync_model_urls();
