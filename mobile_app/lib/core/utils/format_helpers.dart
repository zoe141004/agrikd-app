/// Shared formatting helpers for metric display.
///
/// Server API contract: accuracy, precision, recall, F1 are always
/// in the [0, 1] range. Multiply by 100 for percentage display.
/// Guard: values > 1 are treated as already in percentage form
/// (handles pre-migration-027 data where accuracy is stored as 0-100).
String formatPercent(double? v) {
  if (v == null) return '—';
  final pct = v > 1 ? v : v * 100;
  return '${pct.toStringAsFixed(1)}%';
}
