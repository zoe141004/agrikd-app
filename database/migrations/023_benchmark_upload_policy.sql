-- ============================================================
-- Migration 023: Allow Jetson devices to upload benchmarks
-- Adds RLS policy for anon role to INSERT/UPDATE model_benchmarks
-- Required for on-device TensorRT validation results upload.
-- ============================================================
-- Safe to re-run: DROP IF EXISTS before CREATE.
-- ============================================================

-- Allow anon (Jetson with publishable key) to insert benchmarks
DROP POLICY IF EXISTS "Jetson devices insert benchmarks" ON public.model_benchmarks;
CREATE POLICY "Jetson devices insert benchmarks"
    ON public.model_benchmarks FOR INSERT TO anon
    WITH CHECK (format = 'tensorrt_fp16');

-- Allow anon to update benchmarks (for re-validation of same engine)
DROP POLICY IF EXISTS "Jetson devices update benchmarks" ON public.model_benchmarks;
CREATE POLICY "Jetson devices update benchmarks"
    ON public.model_benchmarks FOR UPDATE TO anon
    USING (format = 'tensorrt_fp16')
    WITH CHECK (format = 'tensorrt_fp16');

-- Also allow anon to PATCH model_engines.benchmark_json
DROP POLICY IF EXISTS "Jetson devices update engine benchmark" ON public.model_engines;
CREATE POLICY "Jetson devices update engine benchmark"
    ON public.model_engines FOR UPDATE TO anon
    USING (true)
    WITH CHECK (true);

COMMENT ON POLICY "Jetson devices insert benchmarks" ON public.model_benchmarks
    IS 'Allows Jetson devices to upload TensorRT validation results';
