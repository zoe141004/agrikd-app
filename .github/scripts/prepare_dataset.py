"""
Prepare a dataset from a ZIP file for DVC tracking.

1. Extracts ZIP to data/{leaf_type}/
2. Validates ImageFolder structure (subfolders with images)
3. Handles nested root folders (e.g. ZIP contains single top-level dir)
4. Auto-generates mlops_pipeline/configs/{leaf_type}.json

Usage:
    python prepare_dataset.py \
        --zip /tmp/dataset.zip \
        --leaf-type mango \
        --display-name "Mango Leaf Disease"
"""

import argparse
import json
import os
import shutil
import sys
import zipfile

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp', '.tiff', '.tif'}


def extract_and_organize(zip_path, leaf_type):
    """Extract ZIP and organize into data/{leaf_type}/{class}/images."""
    data_dir = os.path.join("data", leaf_type)
    temp_dir = os.path.join("data", f"_temp_{leaf_type}")

    # Clean up existing
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir)

    # Extract to temp
    print(f"[...] Extracting {zip_path}...")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(temp_dir)

    # Handle nested root: if temp has single subfolder, use its contents
    entries = [e for e in os.listdir(temp_dir) if not e.startswith('.')]
    if len(entries) == 1 and os.path.isdir(os.path.join(temp_dir, entries[0])):
        nested_root = os.path.join(temp_dir, entries[0])
        print(f"    Detected nested root folder: {entries[0]}")
        source_dir = nested_root
    else:
        source_dir = temp_dir

    # Validate: source_dir should contain subfolders (classes) with images
    class_dirs = sorted([
        d for d in os.listdir(source_dir)
        if os.path.isdir(os.path.join(source_dir, d)) and not d.startswith('.')
    ])

    if not class_dirs:
        print(f"[ERROR] No class subdirectories found in extracted ZIP")
        print(f"    Contents: {os.listdir(source_dir)}")
        shutil.rmtree(temp_dir)
        sys.exit(1)

    # Verify at least some classes have images
    total_images = 0
    for cls in class_dirs:
        cls_path = os.path.join(source_dir, cls)
        imgs = [f for f in os.listdir(cls_path)
                if os.path.isfile(os.path.join(cls_path, f))
                and os.path.splitext(f)[1].lower() in IMAGE_EXTS]
        total_images += len(imgs)
        print(f"    Class '{cls}': {len(imgs)} images")

    if total_images == 0:
        print(f"[ERROR] No image files found in any class directory")
        shutil.rmtree(temp_dir)
        sys.exit(1)

    # Move to final location
    if os.path.exists(data_dir):
        print(f"    Removing existing {data_dir}...")
        shutil.rmtree(data_dir)

    shutil.move(source_dir, data_dir)

    # Clean up temp if it still exists
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir)

    print(f"[OK] Dataset extracted: {len(class_dirs)} classes, {total_images} images")
    return class_dirs


def generate_config(leaf_type, display_name, class_dirs):
    """Auto-generate mlops_pipeline/configs/{leaf_type}.json."""
    config_dir = os.path.join("mlops_pipeline", "configs")
    os.makedirs(config_dir, exist_ok=True)
    config_path = os.path.join(config_dir, f"{leaf_type}.json")

    # Sort alphabetically (ImageFolder convention)
    class_dirs_sorted = sorted(class_dirs)

    classes = {}
    for idx, folder_name in enumerate(class_dirs_sorted):
        # Derive clean name from folder name
        clean_name = folder_name.replace('___', '_').replace('__', '_')
        classes[str(idx)] = {
            "name": clean_name,
            "folder_name": folder_name,
            "display_name": clean_name.replace('_', ' ').title(),
            "description": f"Class: {clean_name}"
        }

    config = {
        "leaf_type": leaf_type,
        "display_name": display_name,
        "num_classes": len(class_dirs_sorted),
        "input_size": [224, 224],
        "input_channels": 3,
        "input_layout": "NCHW",
        "checkpoint_filename": f"{leaf_type}_student.pth",
        "data_dir": f"data/{leaf_type}",
        "class_mapping_note": "Class indices follow ImageFolder alphabetical sort of folder names (training convention).",
        "classes": classes,
        "normalization": {
            "mean": [0.485, 0.456, 0.406],
            "std": [0.229, 0.224, 0.225]
        }
    }

    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=4, ensure_ascii=False)

    print(f"[OK] Config generated: {config_path}")
    print(f"     {len(class_dirs_sorted)} classes: {', '.join(class_dirs_sorted)}")
    return config_path


def main():
    parser = argparse.ArgumentParser(description="Prepare dataset from ZIP for DVC tracking")
    parser.add_argument("--zip", required=True, help="Path to ZIP file")
    parser.add_argument("--leaf-type", required=True, help="Leaf type identifier")
    parser.add_argument("--display-name", default=None, help="Human-readable name")
    args = parser.parse_args()

    if not os.path.exists(args.zip):
        print(f"[ERROR] ZIP file not found: {args.zip}")
        sys.exit(1)

    display_name = args.display_name or args.leaf_type.replace('_', ' ').title()

    print(f"\n{'='*60}")
    print(f"  Dataset Preparation: {args.leaf_type}")
    print(f"{'='*60}")

    class_dirs = extract_and_organize(args.zip, args.leaf_type)
    generate_config(args.leaf_type, display_name, class_dirs)

    print(f"\n[DONE] Dataset ready for DVC tracking.")


if __name__ == "__main__":
    main()
