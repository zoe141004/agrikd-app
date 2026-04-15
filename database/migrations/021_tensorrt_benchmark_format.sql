-- ============================================================
-- Migration 021: Add TensorRT FP16 format to model_benchmarks
-- Allows Jetson on-device validation results to be stored in
-- the same table as CI pipeline benchmarks for unified display.
-- ============================================================
-- Safe to re-run: uses IF NOT EXISTS pattern via constraint replacement.
-- ============================================================

-- Drop and re-add CHECK constraint to include 'tensorrt_fp16'
ALTER TABLE public.model_benchmarks
  DROP CONSTRAINT IF EXISTS model_benchmarks_format_check;

ALTER TABLE public.model_benchmarks
  ADD CONSTRAINT model_benchmarks_format_check
  CHECK (format IN ('pytorch', 'onnx', 'tflite_float16', 'tflite_float32', 'tensorrt_fp16'));

COMMENT ON CONSTRAINT model_benchmarks_format_check ON public.model_benchmarks
  IS 'Allowed inference formats: pytorch, onnx, tflite_float16, tflite_float32, tensorrt_fp16';
