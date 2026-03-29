-- ============================================================================
-- AgriKD Admin Dashboard — Supabase Schema Sync
-- Safe to re-run: uses IF NOT EXISTS, DROP IF EXISTS, ADD COLUMN IF NOT EXISTS
-- Run in Supabase Dashboard → SQL Editor → New query
-- ============================================================================

-- ── 1. Add missing columns to existing tables ────────────────────────────────

-- predictions: already created by 001_init.sql (BIGINT id), just ensure all needed columns exist
ALTER TABLE predictions ADD COLUMN IF NOT EXISTS predicted_class_index integer;
ALTER TABLE predictions ADD COLUMN IF NOT EXISTS all_confidences jsonb;
ALTER TABLE predictions ADD COLUMN IF NOT EXISTS inference_time_ms float;
ALTER TABLE predictions ADD COLUMN IF NOT EXISTS local_id integer;

-- model_registry: add columns the dashboard needs (001_init only has basic columns)
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS model_url text;
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true;
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

-- Sync file_url → model_url: Flutter writes file_url, dashboard reads model_url
-- Ensure both exist; use model_url as canonical, keep file_url as alias for Flutter
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS file_url text;

-- OTA variant selection: admin chooses float16 or float32 TFLite for mobile deployment
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS model_url_float32 text;
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS sha256_float32 text;
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS active_tflite_variant text DEFAULT 'float16';
-- Note: Cannot add CHECK constraint via ALTER in all PG versions; enforced in trigger below

-- Copy file_url values into model_url if model_url is empty (one-time data sync)
UPDATE model_registry SET model_url = file_url WHERE model_url IS NULL AND file_url IS NOT NULL;

-- profiles table (new for admin dashboard)
CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text UNIQUE,
  role text DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

-- audit_log table (new for admin dashboard)
CREATE TABLE IF NOT EXISTS audit_log (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id),
  action text NOT NULL,
  entity_type text,
  entity_id text,
  details jsonb,
  created_at timestamptz DEFAULT now()
);

-- ── 2. Auto-create profile on signup ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
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

-- ── 3. Backfill profiles for existing auth users ────────────────────────────

INSERT INTO profiles (id, email, role)
SELECT id, email, 'user' FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- ── 4. Clean up old policies from 001_init.sql and 002_admin_policies.sql ───

-- Old prediction policies (001_init)
DROP POLICY IF EXISTS "Users can view own predictions" ON predictions;
DROP POLICY IF EXISTS "Users can insert own predictions" ON predictions;
DROP POLICY IF EXISTS "Users can update own predictions" ON predictions;
DROP POLICY IF EXISTS "Users can delete own predictions" ON predictions;

-- Old admin policies (002_admin_policies) using hardcoded email
DROP POLICY IF EXISTS "Admin can read all predictions" ON predictions;
DROP POLICY IF EXISTS "Admin can read all images" ON storage.objects;

-- Old model_registry policy (001_init)
DROP POLICY IF EXISTS "Anyone can read model registry" ON model_registry;

-- Remove is_admin() and ALL policies that depend on it (CASCADE)
DROP FUNCTION IF EXISTS is_admin() CASCADE;

-- ── 5. Admin check function (SECURITY DEFINER bypasses RLS, prevents recursion) ──

CREATE OR REPLACE FUNCTION public.is_admin_role()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- ── 6. Row Level Security (unified, role-based) ─────────────────────────────

-- predictions
ALTER TABLE predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own predictions" ON predictions;
CREATE POLICY "Users read own predictions"
  ON predictions FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin_role());

DROP POLICY IF EXISTS "Users insert own predictions" ON predictions;
CREATE POLICY "Users insert own predictions"
  ON predictions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins update predictions" ON predictions;
CREATE POLICY "Admins update predictions"
  ON predictions FOR UPDATE
  USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete predictions" ON predictions;
CREATE POLICY "Admins delete predictions"
  ON predictions FOR DELETE
  USING (public.is_admin_role());

-- model_registry
ALTER TABLE model_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read models" ON model_registry;
CREATE POLICY "Anyone can read models"
  ON model_registry FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Admins insert models" ON model_registry;
CREATE POLICY "Admins insert models"
  ON model_registry FOR INSERT
  WITH CHECK (public.is_admin_role());

DROP POLICY IF EXISTS "Admins update models" ON model_registry;
CREATE POLICY "Admins update models"
  ON model_registry FOR UPDATE
  USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete models" ON model_registry;
CREATE POLICY "Admins delete models"
  ON model_registry FOR DELETE
  USING (public.is_admin_role());

-- profiles (use auth.uid() = id for own profile, is_admin_role() for admin — no recursion)
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own profile" ON profiles;
CREATE POLICY "Users read own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id OR public.is_admin_role());

DROP POLICY IF EXISTS "Admins manage profiles" ON profiles;
CREATE POLICY "Admins manage profiles"
  ON profiles FOR ALL
  USING (public.is_admin_role());

-- audit_log
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read audit log" ON audit_log;
CREATE POLICY "Admins read audit log"
  ON audit_log FOR SELECT
  USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins insert audit log" ON audit_log;
CREATE POLICY "Admins insert audit log"
  ON audit_log FOR INSERT
  WITH CHECK (public.is_admin_role());

-- ── 6. Storage Buckets ──────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public)
VALUES ('models', 'models', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('datasets', 'datasets', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies: public read, admin write
DROP POLICY IF EXISTS "Public read models" ON storage.objects;
CREATE POLICY "Public read models" ON storage.objects
  FOR SELECT USING (bucket_id = 'models');

DROP POLICY IF EXISTS "Admin upload models" ON storage.objects;
CREATE POLICY "Admin upload models" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'models' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin update models" ON storage.objects;
CREATE POLICY "Admin update models" ON storage.objects
  FOR UPDATE USING (bucket_id = 'models' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin delete models" ON storage.objects;
CREATE POLICY "Admin delete models" ON storage.objects
  FOR DELETE USING (bucket_id = 'models' AND public.is_admin_role());

DROP POLICY IF EXISTS "Public read datasets" ON storage.objects;
CREATE POLICY "Public read datasets" ON storage.objects
  FOR SELECT USING (bucket_id = 'datasets');

DROP POLICY IF EXISTS "Admin upload datasets" ON storage.objects;
CREATE POLICY "Admin upload datasets" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'datasets' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin update datasets" ON storage.objects;
CREATE POLICY "Admin update datasets" ON storage.objects
  FOR UPDATE USING (bucket_id = 'datasets' AND public.is_admin_role());

DROP POLICY IF EXISTS "Admin delete datasets" ON storage.objects;
CREATE POLICY "Admin delete datasets" ON storage.objects
  FOR DELETE USING (bucket_id = 'datasets' AND public.is_admin_role());

-- Keep existing prediction-images policies from 001_init (user-scoped)
DROP POLICY IF EXISTS "Users upload own images" ON storage.objects;
CREATE POLICY "Users upload own images"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'prediction-images' AND
        (storage.foldername(name))[1] = auth.uid()::text
    );

DROP POLICY IF EXISTS "Users read own images" ON storage.objects;
CREATE POLICY "Users read own images"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'prediction-images' AND
        (storage.foldername(name))[1] = auth.uid()::text
    );

-- Admin can also read all images (replaces old is_admin() policy)
DROP POLICY IF EXISTS "Admin read all images" ON storage.objects;
CREATE POLICY "Admin read all images"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'prediction-images' AND public.is_admin_role());

-- ── 7. Indexes ──────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_predictions_user_id ON predictions(user_id);
CREATE INDEX IF NOT EXISTS idx_predictions_leaf_type ON predictions(leaf_type);
CREATE INDEX IF NOT EXISTS idx_predictions_created_at ON predictions(created_at);
CREATE INDEX IF NOT EXISTS idx_predictions_confidence ON predictions(confidence);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at);

-- ── 8. Create trigger to keep model_url/file_url in sync + OTA variant routing ──
-- Dashboard writes model_url (float16) + model_url_float32
-- Admin sets active_tflite_variant to choose which goes to file_url (read by Flutter)

CREATE OR REPLACE FUNCTION sync_model_urls()
RETURNS trigger AS $$
BEGIN
  -- Enforce variant values
  IF NEW.active_tflite_variant IS NOT NULL AND NEW.active_tflite_variant NOT IN ('float16', 'float32') THEN
    NEW.active_tflite_variant := 'float16';
  END IF;

  -- Route file_url based on admin's variant choice
  IF COALESCE(NEW.active_tflite_variant, 'float16') = 'float32' AND NEW.model_url_float32 IS NOT NULL THEN
    NEW.file_url := NEW.model_url_float32;
    -- Route sha256_checksum from float32 if sha256_float32 is set
    IF NEW.sha256_float32 IS NOT NULL THEN
      NEW.sha256_checksum := NEW.sha256_float32;
    END IF;
  ELSIF NEW.model_url IS NOT NULL THEN
    NEW.file_url := NEW.model_url;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sync_model_urls_trigger ON model_registry;
CREATE TRIGGER sync_model_urls_trigger
  BEFORE UPDATE ON model_registry
  FOR EACH ROW EXECUTE FUNCTION sync_model_urls();

-- Also sync on insert
DROP TRIGGER IF EXISTS sync_model_urls_insert_trigger ON model_registry;
CREATE TRIGGER sync_model_urls_insert_trigger
  BEFORE INSERT ON model_registry
  FOR EACH ROW EXECUTE FUNCTION sync_model_urls();

-- ── 9. Model benchmarks table (full evaluate results) ─────────────────────

CREATE TABLE IF NOT EXISTS model_benchmarks (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  leaf_type text NOT NULL,
  version text NOT NULL,
  format text NOT NULL CHECK (format IN ('pytorch', 'onnx', 'tflite_float16', 'tflite_float32')),
  accuracy float,
  precision_macro float,
  recall_macro float,
  f1_macro float,
  per_class_metrics jsonb,
  confusion_matrix jsonb,
  latency_mean_ms float,
  latency_p99_ms float,
  fps float,
  size_mb float,
  flops_m float,
  params_m float,
  memory_mb float,
  kl_divergence float,
  is_candidate boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  UNIQUE(leaf_type, version, format)
);

ALTER TABLE model_benchmarks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read benchmarks" ON model_benchmarks;
CREATE POLICY "Anyone can read benchmarks"
  ON model_benchmarks FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Admins insert benchmarks" ON model_benchmarks;
CREATE POLICY "Admins insert benchmarks"
  ON model_benchmarks FOR INSERT
  WITH CHECK (public.is_admin_role());

DROP POLICY IF EXISTS "Admins update benchmarks" ON model_benchmarks;
CREATE POLICY "Admins update benchmarks"
  ON model_benchmarks FOR UPDATE
  USING (public.is_admin_role());

DROP POLICY IF EXISTS "Admins delete benchmarks" ON model_benchmarks;
CREATE POLICY "Admins delete benchmarks"
  ON model_benchmarks FOR DELETE
  USING (public.is_admin_role());

CREATE INDEX IF NOT EXISTS idx_model_benchmarks_leaf_type ON model_benchmarks(leaf_type);

-- ── 10. Model version archive table ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS model_versions (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  leaf_type text NOT NULL,
  version text NOT NULL,
  display_name text,
  model_url text,
  sha256_checksum text,
  accuracy float,
  size_mb float,
  archived_at timestamptz DEFAULT now(),
  UNIQUE(leaf_type, version)
);

ALTER TABLE model_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read model versions" ON model_versions;
CREATE POLICY "Anyone can read model versions"
  ON model_versions FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Admins manage model versions" ON model_versions;
CREATE POLICY "Admins manage model versions"
  ON model_versions FOR ALL
  USING (public.is_admin_role());

CREATE INDEX IF NOT EXISTS idx_model_versions_leaf_type ON model_versions(leaf_type);

-- ============================================================================
-- DONE! Next steps:
-- 1. Set admin: UPDATE profiles SET role = 'admin' WHERE email = 'your@email.com';
-- 2. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in Vercel env vars
-- ============================================================================
