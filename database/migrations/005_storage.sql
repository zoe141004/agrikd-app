-- =============================================================================
-- AgriKD — 005: Storage Buckets & Policies
-- =============================================================================
-- Source of truth: admin-dashboard/supabase-schema.sql
-- Safe to re-run: ON CONFLICT, DROP IF EXISTS before CREATE POLICY.
-- =============================================================================

-- ── Create buckets ──────────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public)
VALUES ('models', 'models', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('datasets', 'datasets', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('prediction-images', 'prediction-images', false)
ON CONFLICT (id) DO NOTHING;

-- ── Models bucket: public read, admin write/update/delete ───────────────────

DROP POLICY IF EXISTS "Public read models" ON storage.objects;
CREATE POLICY "Public read models"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'models');

DROP POLICY IF EXISTS "Admin upload models" ON storage.objects;
CREATE POLICY "Admin upload models"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'models' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin update models" ON storage.objects;
CREATE POLICY "Admin update models"
    ON storage.objects FOR UPDATE
    USING (bucket_id = 'models' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin delete models" ON storage.objects;
CREATE POLICY "Admin delete models"
    ON storage.objects FOR DELETE
    USING (bucket_id = 'models' AND public.is_admin_role());

-- ── Datasets bucket: public read, admin write/update/delete ─────────────────

DROP POLICY IF EXISTS "Public read datasets" ON storage.objects;
CREATE POLICY "Public read datasets"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'datasets');

DROP POLICY IF EXISTS "Admin upload datasets" ON storage.objects;
CREATE POLICY "Admin upload datasets"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'datasets' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin update datasets" ON storage.objects;
CREATE POLICY "Admin update datasets"
    ON storage.objects FOR UPDATE
    USING (bucket_id = 'datasets' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin delete datasets" ON storage.objects;
CREATE POLICY "Admin delete datasets"
    ON storage.objects FOR DELETE
    USING (bucket_id = 'datasets' AND public.is_admin_role());

-- ── Prediction-images bucket: user-scoped + admin read ──────────────────────

DROP POLICY IF EXISTS "Users upload own images" ON storage.objects;
CREATE POLICY "Users upload own images"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'prediction-images'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

DROP POLICY IF EXISTS "Users read own images" ON storage.objects;
CREATE POLICY "Users read own images"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'prediction-images'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

DROP POLICY IF EXISTS "Admin read all images" ON storage.objects;
CREATE POLICY "Admin read all images"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'prediction-images' AND public.is_admin_role());
