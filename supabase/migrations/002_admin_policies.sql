-- ============================================================
-- AgriKD Admin Access Policies
-- Run this SQL in Supabase Dashboard > SQL Editor
-- Requires: Admin user to be created first via Supabase Auth
-- ============================================================

-- Option 1: Allow admin user (by email) to read all predictions
-- Replace 'admin@agrikd.com' with actual admin email
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM auth.users
    WHERE id = auth.uid()
    AND email IN ('agrikd.admin@gmail.com')
  );
$$ LANGUAGE sql SECURITY DEFINER;

-- Admin can read all predictions
CREATE POLICY "Admin can read all predictions"
    ON predictions FOR SELECT
    USING (is_admin());

-- Admin can read all storage objects
CREATE POLICY "Admin can read all images"
    ON storage.objects FOR SELECT
    USING (is_admin());
