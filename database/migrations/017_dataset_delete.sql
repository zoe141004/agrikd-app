-- Migration 017: Add 'delete' operation and 'deleting' status for dataset deletion
-- Supports the dataset-delete.yml GitHub Actions workflow

-- ── 1. Extend operation CHECK constraint to include 'delete' ────────────────
ALTER TABLE public.dvc_operations
  DROP CONSTRAINT IF EXISTS dvc_operations_operation_check;

ALTER TABLE public.dvc_operations
  ADD CONSTRAINT dvc_operations_operation_check
  CHECK (operation IN ('stage', 'push', 'pull', 'export', 'delete'));

-- ── 2. Extend status CHECK constraint to include 'deleting' ────────────────
ALTER TABLE public.dvc_operations
  DROP CONSTRAINT IF EXISTS dvc_operations_status_check;

ALTER TABLE public.dvc_operations
  ADD CONSTRAINT dvc_operations_status_check
  CHECK (status IN (
    'pending', 'staging', 'staged', 'pushing',
    'pulling', 'exporting', 'deleting', 'completed', 'failed'
  ));
