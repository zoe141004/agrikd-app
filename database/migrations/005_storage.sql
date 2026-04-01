-- =============================================================================
-- AgriKD — 005: Storage Buckets & Policies
-- =============================================================================

-- Create buckets (idempotent via ON CONFLICT)
INSERT INTO storage.buckets (id, name, public)
VALUES
    ('models', 'models', true),
    ('datasets', 'datasets', false),
    ('prediction-images', 'prediction-images', false)
ON CONFLICT (id) DO NOTHING;

-- ── Storage policies ──────────────────────────────────────────────────────────

-- Models bucket: public read, admin write
CREATE POLICY "Public read models"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'models');

CREATE POLICY "Admins upload models"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'models' AND public.is_admin_role());

-- Datasets bucket: admin only
CREATE POLICY "Admins read datasets"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'datasets' AND public.is_admin_role());

CREATE POLICY "Admins upload datasets"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'datasets' AND public.is_admin_role());

-- Prediction images: users can upload to their own path, admins can read all
CREATE POLICY "Users upload own prediction images"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'prediction-images'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "Users read own prediction images"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'prediction-images'
        AND (storage.foldername(name))[1] = auth.uid()::text
    );

CREATE POLICY "Admins read all prediction images"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'prediction-images' AND public.is_admin_role());

-- TODO: Verify these policies match your actual Supabase storage configuration.
-- Export from Dashboard: Storage → Policies tab.
