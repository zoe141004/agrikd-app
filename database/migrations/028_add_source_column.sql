-- 028: Add missing source column to predictions + re-normalize accuracy
--
-- Root cause: migration 001_tables.sql defined source TEXT in CREATE TABLE IF NOT EXISTS,
-- but the table was originally created without it. Since CREATE TABLE IF NOT EXISTS skips
-- if the table already exists, the column was never added. The device_push_predictions RPC
-- (migration 026) INSERTs into source, causing: "column source does not exist".
--
-- Also re-normalize accuracy values that may have been inserted as percentages (0-100)
-- after migration 027 ran. The WHERE > 1 guard makes this idempotent.

ALTER TABLE public.predictions ADD COLUMN IF NOT EXISTS source TEXT;

-- Re-normalize any accuracy values that slipped through as percentages
UPDATE public.model_benchmarks
SET accuracy = accuracy / 100.0
WHERE accuracy IS NOT NULL AND accuracy > 1;

UPDATE public.model_registry
SET accuracy_top1 = accuracy_top1 / 100.0
WHERE accuracy_top1 IS NOT NULL AND accuracy_top1 > 1;

UPDATE public.model_versions
SET accuracy = accuracy / 100.0
WHERE accuracy IS NOT NULL AND accuracy > 1;
