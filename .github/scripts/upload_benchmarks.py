"""
Upload pipeline results to Supabase after model-pipeline.yml completes.

1. Upload converted models (.pth, .onnx, .tflite float16/float32) to Supabase Storage
2. Parse benchmark_report.md and write metrics to model_benchmarks table
3. Update model_registry with accuracy, model_url (float16/float32), sha256

Env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LEAF_TYPE, VERSION,
          TFLITE_FLOAT16_SHA256, TFLITE_FLOAT32_SHA256
"""

import json
import os
import re
import sys
import urllib.request
import urllib.error
import urllib.parse


def supabase_request(url, headers, body=None, method="POST"):
    """Make an HTTP request and return (success, response_body)."""
    data = json.dumps(body, default=str).encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return True, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return False, e.read().decode("utf-8")


def upload_file_to_storage(supabase_url, service_key, local_path, storage_path):
    """Upload a file to Supabase Storage bucket 'models'. Returns public URL or None."""
    if not os.path.exists(local_path):
        print(f"  [SKIP] File not found: {local_path}")
        return None

    upload_url = f"{supabase_url}/storage/v1/object/models/{storage_path}"

    with open(local_path, "rb") as f:
        file_data = f.read()

    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/octet-stream",
        "x-upsert": "true",
    }

    req = urllib.request.Request(upload_url, data=file_data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            public_url = f"{supabase_url}/storage/v1/object/public/models/{storage_path}"
            size_mb = len(file_data) / (1024 * 1024)
            ext = os.path.splitext(local_path)[1]
            print(f"  [OK] Uploaded {ext}: {public_url} ({size_mb:.2f} MB)")
            return public_url
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        print(f"  [FAIL] Upload {local_path} failed: {e.code} — {error_body}")
        return None


def upload_all_models(supabase_url, service_key, leaf_type, version):
    """Upload PTH, ONNX, TFLite float16, and TFLite float32 to Supabase Storage. Returns dict of URLs."""
    prefix = f"{leaf_type}/v{version}"
    models_dir = f"models/{leaf_type}"
    checkpoint_dir = "model_checkpoints_student"

    files = [
        (f"{checkpoint_dir}/{leaf_type}_student.pth",           f"{prefix}/{leaf_type}_v{version}_checkpoint.pth", "pth"),
        (f"{models_dir}/{leaf_type}_student.onnx",              f"{prefix}/{leaf_type}_v{version}.onnx",           "onnx"),
        (f"{models_dir}/{leaf_type}_student_float16.tflite",    f"{prefix}/{leaf_type}_v{version}_float16.tflite", "tflite_float16"),
        (f"{models_dir}/{leaf_type}_student_float32.tflite",    f"{prefix}/{leaf_type}_v{version}_float32.tflite", "tflite_float32"),
    ]

    urls = {}
    for local_path, storage_path, key in files:
        url = upload_file_to_storage(supabase_url, service_key, local_path, storage_path)
        urls[key] = url

    return urls


def parse_benchmark_report(report_path):
    """Parse benchmark_report.md and extract metrics per format."""
    with open(report_path, "r", encoding="utf-8") as f:
        content = f.read()

    results = []

    # Parse main benchmark table
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
        fmt_name = row_dict.get("Format", "").strip()
        # Map report format names to DB format names
        fmt_map = {
            "pytorch": "pytorch",
            "onnx": "onnx",
            "tflite": "tflite_float16",  # backward compat
            "tflite (float16)": "tflite_float16",
            "tflite (float32)": "tflite_float32",
        }
        fmt_key = fmt_map.get(fmt_name.lower())
        if not fmt_key:
            continue
        results.append({
            "format": fmt_key,
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
            fmt_name = row_dict.get("Format", "").strip()
            fmt_map = {
                "pytorch": "pytorch", "onnx": "onnx",
                "tflite": "tflite_float16",
                "tflite (float16)": "tflite_float16",
                "tflite (float32)": "tflite_float32",
            }
            fmt_key = fmt_map.get(fmt_name.lower())
            for r in results:
                if r["format"] == fmt_key:
                    r["latency_p99_ms"] = safe_float(row_dict.get("Lat P99 (ms)"))

    # Parse per-class classification metrics per format
    class_sections = re.findall(
        r"### ([^\n—]+?) \u2014 Per-Class Metrics\s+\|([^\n]+)\n\|[-\s|]+\n((?:\|[^\n]+\n)+)",
        content
    )
    fmt_map = {
        "pytorch": "pytorch", "onnx": "onnx",
        "tflite": "tflite_float16",
        "tflite (float16)": "tflite_float16",
        "tflite (float32)": "tflite_float32",
    }
    for fmt_name, headers_str, rows_str in class_sections:
        fmt_lower = fmt_map.get(fmt_name.strip().lower(), fmt_name.strip().lower())
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
    tflite_f16_sha256 = os.environ.get("TFLITE_FLOAT16_SHA256", "")
    tflite_f32_sha256 = os.environ.get("TFLITE_FLOAT32_SHA256", "")

    if not all([supabase_url, service_key, leaf_type, version]):
        print("[ERROR] Missing env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LEAF_TYPE, VERSION")
        sys.exit(1)

    api_headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }

    # ── 1. Upload all model formats to Supabase Storage ─────────────────────
    print("\n=== Step 1: Upload model files to Supabase Storage ===")
    model_urls = upload_all_models(supabase_url, service_key, leaf_type, version)
    tflite_f16_url = model_urls.get("tflite_float16")
    tflite_f32_url = model_urls.get("tflite_float32")

    # ── 2. Update model_registry with model_url + sha256 ──────────────────
    if tflite_f16_url or tflite_f32_url:
        print("\n=== Step 2: Update model_registry ===")
        registry_update = {
            "updated_at": "now()",
        }
        if tflite_f16_url:
            registry_update["model_url"] = tflite_f16_url
        if tflite_f32_url:
            registry_update["model_url_float32"] = tflite_f32_url
        if tflite_f16_sha256:
            registry_update["sha256_checksum"] = tflite_f16_sha256
        if tflite_f32_sha256:
            registry_update["sha256_float32"] = tflite_f32_sha256

        encoded_leaf = urllib.parse.quote(leaf_type, safe="")
        encoded_ver = urllib.parse.quote(version, safe="")
        url = f"{supabase_url}/rest/v1/model_registry?leaf_type=eq.{encoded_leaf}&version=eq.{encoded_ver}"
        ok, resp = supabase_request(url, {**api_headers, "Prefer": "return=minimal"}, registry_update, "PATCH")
        if ok:
            print(f"  [OK] model_registry updated (float16 + float32 URLs)")
        else:
            # Version might not match — try matching just leaf_type
            url2 = f"{supabase_url}/rest/v1/model_registry?leaf_type=eq.{encoded_leaf}"
            ok2, resp2 = supabase_request(url2, {**api_headers, "Prefer": "return=minimal"}, registry_update, "PATCH")
            if ok2:
                print(f"  [OK] model_registry updated (by leaf_type)")
            else:
                print(f"  [WARN] Could not update model_registry: {resp2}")

    # ── 3. Parse benchmark report and write to model_benchmarks ──────────────
    report_path = f"models/{leaf_type}/benchmark_report.md"
    if not os.path.exists(report_path):
        print(f"\n[WARN] Report not found: {report_path} — skipping benchmark upload")
        print("[DONE] Pipeline upload complete (partial — no benchmarks).")
        return

    print(f"\n=== Step 3: Upload benchmark results ===")
    results = parse_benchmark_report(report_path)
    print(f"[*] Found {len(results)} format results")

    # Delete old benchmark records for this leaf_type + version first
    encoded_leaf = urllib.parse.quote(leaf_type, safe="")
    encoded_ver = urllib.parse.quote(version, safe="")
    del_url = f"{supabase_url}/rest/v1/model_benchmarks?leaf_type=eq.{encoded_leaf}&version=eq.{encoded_ver}"
    ok_del, resp_del = supabase_request(del_url, {**api_headers, "Prefer": "return=minimal"}, method="DELETE")
    if ok_del:
        print(f"  [OK] Cleared old benchmarks for {leaf_type} v{version}")
    else:
        print(f"  [WARN] Could not clear old benchmarks: {resp_del}")

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

        url = f"{supabase_url}/rest/v1/model_benchmarks"
        ok, resp = supabase_request(url, {**api_headers, "Prefer": "return=minimal"}, payload)
        if ok:
            print(f"  [OK] {r['format']}: accuracy={r.get('accuracy')}, latency={r.get('latency_mean_ms')}ms")
        else:
            print(f"  [FAIL] {r['format']}: {resp}")

    # Update accuracy_top1 in model_registry from TFLite float16 result
    tflite_result = next((r for r in results if r["format"] == "tflite_float16"), None)
    if tflite_result and tflite_result.get("accuracy") is not None:
        encoded_leaf = urllib.parse.quote(leaf_type, safe="")
        url = f"{supabase_url}/rest/v1/model_registry?leaf_type=eq.{encoded_leaf}"
        ok, resp = supabase_request(
            url,
            {**api_headers, "Prefer": "return=minimal"},
            {"accuracy_top1": tflite_result["accuracy"]},
            "PATCH"
        )
        if ok:
            print(f"  [OK] model_registry accuracy_top1 = {tflite_result['accuracy']}%")
        else:
            print(f"  [WARN] Could not update accuracy: {resp}")

    print("\n[DONE] Pipeline upload complete.")


if __name__ == "__main__":
    main()
