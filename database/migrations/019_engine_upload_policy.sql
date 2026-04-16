-- Migration 019: Allow Jetson devices to upload .engine files via anon key
--
-- TensorRT .engine files are device-specific (GPU arch + TRT version).
-- Jetson devices convert ONNX → TensorRT locally, then upload the .engine
-- to Supabase Storage as a backup under models/engines/{device_tag}/.
--
-- This policy grants INSERT (upload) permission to anon role ONLY for
-- the engines/ prefix inside the 'models' bucket. It does NOT grant
-- read, update, or delete — those remain admin-only.
--
-- Storage path convention:
--   models/engines/{jetson-orin-nano_trt10.3}/{leaf_type}_student.engine

-- Allow anon to upload .engine files into engines/ folder
DROP POLICY IF EXISTS "jetson_engine_upload" ON storage.objects;
CREATE POLICY "jetson_engine_upload"
ON storage.objects FOR INSERT
TO anon
WITH CHECK (
    bucket_id = 'models'
    AND name LIKE 'engines/%'
);

-- Allow anon to overwrite (upsert) existing .engine files
-- x-upsert: true in the upload request triggers UPDATE, not just INSERT
DROP POLICY IF EXISTS "jetson_engine_upsert" ON storage.objects;
CREATE POLICY "jetson_engine_upsert"
ON storage.objects FOR UPDATE
TO anon
USING (
    bucket_id = 'models'
    AND name LIKE 'engines/%'
)
WITH CHECK (
    bucket_id = 'models'
    AND name LIKE 'engines/%'
);

-- Allow anon to read .engine files (for re-download on fresh setup)
DROP POLICY IF EXISTS "jetson_engine_read" ON storage.objects;
CREATE POLICY "jetson_engine_read"
ON storage.objects FOR SELECT
TO anon
USING (
    bucket_id = 'models'
    AND name LIKE 'engines/%'
);
