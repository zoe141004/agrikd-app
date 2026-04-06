"""
Export user predictions from Supabase as a labeled image dataset.

Queries predictions with confidence >= threshold, downloads images,
and organizes into data/{leaf_type}/{class_name}/ structure.

Usage:
    python export_predictions_to_dataset.py \
        --leaf-type tomato \
        --confidence 0.8 \
        --output-dir data/tomato_predictions

Env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error


def main():
    parser = argparse.ArgumentParser(description="Export predictions as labeled dataset")
    parser.add_argument("--leaf-type", required=True, help="Leaf type to export")
    parser.add_argument("--confidence", type=float, default=0.8, help="Min confidence threshold")
    parser.add_argument("--output-dir", required=True, help="Output directory for dataset")
    args = parser.parse_args()

    supabase_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

    if not supabase_url or not service_key:
        print("[ERROR] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")
        sys.exit(1)

    print(f"\n{'='*60}")
    print(f"  Export Predictions: {args.leaf_type}")
    print(f"  Confidence >= {args.confidence}")
    print(f"{'='*60}")

    # Query predictions
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }

    # Fetch predictions with image_url
    url = (
        f"{supabase_url}/rest/v1/predictions"
        f"?leaf_type=eq.{args.leaf_type}"
        f"&confidence=gte.{args.confidence}"
        f"&select=id,predicted_class_name,confidence,image_url"
        f"&order=confidence.desc"
        f"&limit=10000"
    )

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            predictions = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"[ERROR] Failed to query predictions: {e.code} — {e.read().decode()}")
        sys.exit(1)

    if not predictions:
        print("[WARN] No predictions found matching criteria")
        sys.exit(0)

    print(f"[*] Found {len(predictions)} predictions")

    # Group by class
    class_counts = {}
    for p in predictions:
        cls = p.get("predicted_class_name", "unknown")
        class_counts[cls] = class_counts.get(cls, 0) + 1

    print("[*] Distribution:")
    for cls, count in sorted(class_counts.items()):
        print(f"    {cls}: {count}")

    # Download images
    os.makedirs(args.output_dir, exist_ok=True)
    downloaded = 0
    skipped = 0

    for p in predictions:
        cls = p.get("predicted_class_name", "unknown")
        image_url = p.get("image_url")

        if not image_url:
            skipped += 1
            continue

        cls_dir = os.path.join(args.output_dir, cls)
        os.makedirs(cls_dir, exist_ok=True)

        # Derive filename from prediction id
        ext = os.path.splitext(image_url.split("?")[0])[1] or ".jpg"
        filename = f"{p['id']}{ext}"
        filepath = os.path.join(cls_dir, filename)

        if os.path.exists(filepath):
            downloaded += 1
            continue

        try:
            # Authenticated download: private buckets need apikey + Bearer token
            # Convert public URLs to authenticated path for private buckets
            dl_url = image_url.replace('/object/public/', '/object/authenticated/')
            dl_headers = {
                "apikey": service_key,
                "Authorization": f"Bearer {service_key}",
            }
            dl_req = urllib.request.Request(dl_url, headers=dl_headers)
            with urllib.request.urlopen(dl_req) as resp:
                with open(filepath, 'wb') as out_f:
                    out_f.write(resp.read())
            downloaded += 1
        except Exception as e:
            print(f"    [SKIP] Failed to download {p['id']}: {e}")
            skipped += 1

    print(f"\n[OK] Downloaded {downloaded} images, skipped {skipped}")

    # Generate config if it doesn't exist
    config_path = os.path.join("mlops_pipeline", "configs", f"{args.leaf_type}.json")
    if not os.path.exists(config_path):
        class_dirs = sorted([
            d for d in os.listdir(args.output_dir)
            if os.path.isdir(os.path.join(args.output_dir, d))
        ])
        classes = {}
        for idx, folder_name in enumerate(class_dirs):
            classes[str(idx)] = {
                "name": folder_name,
                "folder_name": folder_name,
                "display_name": folder_name.replace('_', ' ').title(),
                "description": f"Class: {folder_name}"
            }

        config = {
            "leaf_type": args.leaf_type,
            "display_name": args.leaf_type.replace('_', ' ').title(),
            "num_classes": len(class_dirs),
            "input_size": [224, 224],
            "input_channels": 3,
            "checkpoint_filename": f"{args.leaf_type}_student.pth",
            "data_dir": f"data/{args.leaf_type}",
            "class_mapping_note": "Class indices follow ImageFolder alphabetical sort of folder names.",
            "classes": classes,
            "normalization": {
                "mean": [0.485, 0.456, 0.406],
                "std": [0.229, 0.224, 0.225]
            }
        }

        os.makedirs(os.path.dirname(config_path), exist_ok=True)
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=4, ensure_ascii=False)
        print(f"[OK] Config generated: {config_path}")
    else:
        print(f"[OK] Config already exists: {config_path}")

    print(f"\n[DONE] Dataset exported to {args.output_dir}")


if __name__ == "__main__":
    main()
