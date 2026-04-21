/// Shared formatting helpers for metric display.
///
/// Server API contract: accuracy, precision, recall, F1 are always
/// in the [0, 1] range. Multiply by 100 for percentage display.
String formatPercent(double? v) {
  if (v == null) return '—';
  final pct = v * 100;
  return '${pct.toStringAsFixed(1)}%';
}
