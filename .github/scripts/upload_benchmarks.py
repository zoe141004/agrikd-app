"""
Upload benchmark results from evaluate_models.py to Supabase model_benchmarks table.

Called by .github/workflows/model-pipeline.yml after evaluate completes.
Reads the benchmark_report.md and parses metrics for each format (PyTorch, ONNX, TFLite).

Env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LEAF_TYPE, VERSION
"""

import json
import os
import re
import sys

def parse_benchmark_report(report_path):
    """Parse benchmark_report.md and extract metrics per format."""
    with open(report_path, "r", encoding="utf-8") as f:
        content = f.read()

    results = []

    # Parse main benchmark table
    # Format: | Format | Size (MB) | Params (M) | FLOPs (M) | ms/img | FPS | Runtime Mem (MB) | Top-1 % | KL Div |
    table_match = re.search(
        r"### Benchmark Summary\s+\|(.+?)\n\|[-\s|]+\n((?:\|.+\n)+)",
        content, re.DOTALL
    )
    if not table_match:
        print("[ERROR] Could not find Benchmark Summary table")
        sys.exit(1)

    headers_raw = [h.strip() for h in table_match.group(1).split("|") if h.strip()]
    rows_raw = table_match.group(2).strip().split("\n")

    for row in rows_raw:
        cells = [c.strip() for c in row.split("|") if c.strip()]
        if len(cells) < len(headers_raw):
            continue
        row_dict = dict(zip(headers_raw, cells))
        fmt_name = row_dict.get("Format", "").lower()
        if fmt_name not in ("pytorch", "onnx", "tflite"):
            continue
        results.append({
            "format": fmt_name,
            "size_mb": safe_float(row_dict.get("Size (MB)")),
            "params_m": safe_float(row_dict.get("Params (M)")),
            "flops_m": safe_float(row_dict.get("FLOPs (M)")),
            "latency_mean_ms": safe_float(row_dict.get("ms/img")),
            "fps": safe_float(row_dict.get("FPS")),
            "memory_mb": safe_float(row_dict.get("Runtime Mem (MB)")),
            "accuracy": safe_float(row_dict.get("Top-1 %")),
            "kl_divergence": safe_float(row_dict.get("KL Div")),
        })

    # Parse latency details table for P99
    lat_match = re.search(
        r"### Latency Details\s+\|(.+?)\n\|[-\s|]+\n((?:\|.+\n)+)",
        content, re.DOTALL
    )
    if lat_match:
        lat_headers = [h.strip() for h in lat_match.group(1).split("|") if h.strip()]
        lat_rows = lat_match.group(2).strip().split("\n")
        for row in lat_rows:
            cells = [c.strip() for c in row.split("|") if c.strip()]
            if len(cells) < len(lat_headers):
                continue
            row_dict = dict(zip(lat_headers, cells))
            fmt_name = row_dict.get("Format", "").lower()
            for r in results:
                if r["format"] == fmt_name:
                    r["latency_p99_ms"] = safe_float(row_dict.get("Lat P99 (ms)"))

    # Parse per-class classification metrics per format
    class_sections = re.findall(
        r"### (\w+) — Per-Class Metrics\s+\|(.+?)\n\|[-\s|]+\n((?:\|.+\n)+)",
        content, re.DOTALL
    )
    for fmt_name, headers_str, rows_str in class_sections:
        fmt_lower = fmt_name.lower()
        headers = [h.strip() for h in headers_str.split("|") if h.strip()]
        rows = rows_str.strip().split("\n")
        per_class = []
        macro_prec = None
        macro_rec = None
        macro_f1 = None
        for row in rows:
            cells = [c.strip() for c in row.split("|") if c.strip()]
            if len(cells) < len(headers):
                continue
            row_dict = dict(zip(headers, cells))
            cls_name = row_dict.get("Class", "")
            if cls_name.lower() == "macro avg":
                macro_prec = safe_float(row_dict.get("Precision"))
                macro_rec = safe_float(row_dict.get("Recall"))
                macro_f1 = safe_float(row_dict.get("F1-Score"))
            elif cls_name.lower() not in ("weighted avg", ""):
                per_class.append({
                    "class": cls_name,
                    "precision": safe_float(row_dict.get("Precision")),
                    "recall": safe_float(row_dict.get("Recall")),
                    "f1": safe_float(row_dict.get("F1-Score")),
                    "support": int(safe_float(row_dict.get("Support")) or 0),
                })

        for r in results:
            if r["format"] == fmt_lower:
                r["per_class_metrics"] = per_class
                r["precision_macro"] = macro_prec
                r["recall_macro"] = macro_rec
                r["f1_macro"] = macro_f1

    return results


def safe_float(val):
    if val is None:
        return None
    try:
        v = val.strip().replace(",", "")
        if v in ("-", ""):
            return None
        return float(v)
    except (ValueError, AttributeError):
        return None


def main():
    supabase_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    leaf_type = os.environ.get("LEAF_TYPE")
    version = os.environ.get("VERSION")

    if not all([supabase_url, service_key, leaf_type, version]):
        print("[ERROR] Missing env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LEAF_TYPE, VERSION")
        sys.exit(1)

    report_path = f"models/{leaf_type}/benchmark_report.md"
    if not os.path.exists(report_path):
        print(f"[ERROR] Report not found: {report_path}")
        sys.exit(1)

    print(f"[*] Parsing benchmark report: {report_path}")
    results = parse_benchmark_report(report_path)
    print(f"[*] Found {len(results)} format results")

    # Write to Supabase via REST API (no SDK needed)
    import urllib.request

    for r in results:
        payload = {
            "leaf_type": leaf_type,
            "version": version,
            "format": r["format"],
            "accuracy": r.get("accuracy"),
            "precision_macro": r.get("precision_macro"),
            "recall_macro": r.get("recall_macro"),
            "f1_macro": r.get("f1_macro"),
            "per_class_metrics": r.get("per_class_metrics"),
            "latency_mean_ms": r.get("latency_mean_ms"),
            "latency_p99_ms": r.get("latency_p99_ms"),
            "fps": r.get("fps"),
            "size_mb": r.get("size_mb"),
            "flops_m": r.get("flops_m"),
            "params_m": r.get("params_m"),
            "memory_mb": r.get("memory_mb"),
            "kl_divergence": r.get("kl_divergence"),
            "is_candidate": True,
        }

        # Upsert: use Prefer: resolution=merge-duplicates header
        url = f"{supabase_url}/rest/v1/model_benchmarks"
        headers = {
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        }

        body = json.dumps(payload, default=str).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                print(f"  [OK] {r['format']}: accuracy={r.get('accuracy')}, latency={r.get('latency_mean_ms')}ms")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8")
            print(f"  [FAIL] {r['format']}: {e.code} — {error_body}")

    # Also update model_registry accuracy_top1 from the TFLite result
    tflite_result = next((r for r in results if r["format"] == "tflite"), None)
    if tflite_result and tflite_result.get("accuracy") is not None:
        url = f"{supabase_url}/rest/v1/model_registry?leaf_type=eq.{leaf_type}&version=eq.{version}"
        headers = {
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        }
        body = json.dumps({"accuracy_top1": tflite_result["accuracy"]}).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=headers, method="PATCH")
        try:
            with urllib.request.urlopen(req) as resp:
                print(f"  [OK] Updated model_registry accuracy_top1 = {tflite_result['accuracy']}%")
        except urllib.error.HTTPError as e:
            print(f"  [WARN] Could not update model_registry: {e.code}")

    print("\n[DONE] Benchmark results uploaded to Supabase.")


if __name__ == "__main__":
    main()
