-- 027: Normalize accuracy values from percentage (0-100) to fraction (0-1)
--
-- Root cause: evaluate_models.py stores accuracy as percentage (87.19),
-- while precision/recall/f1 are stored as fractions (0.8720).
-- This caused the Flutter app to display accuracy as 8719.0% instead of 87.2%.
--
-- After this migration, all classification metrics (accuracy, precision, recall, f1)
-- are consistently in the [0, 1] range across all tables.
--
-- The WHERE > 1 guard makes this migration idempotent.

-- model_benchmarks: per-format evaluation results
UPDATE public.model_benchmarks
SET accuracy = accuracy / 100.0
WHERE accuracy IS NOT NULL AND accuracy > 1;

-- model_registry: top-1 accuracy for OTA display
UPDATE public.model_registry
SET accuracy_top1 = accuracy_top1 / 100.0
WHERE accuracy_top1 IS NOT NULL AND accuracy_top1 > 1;

-- model_versions: archived version snapshots
UPDATE public.model_versions
SET accuracy = accuracy / 100.0
WHERE accuracy IS NOT NULL AND accuracy > 1;
