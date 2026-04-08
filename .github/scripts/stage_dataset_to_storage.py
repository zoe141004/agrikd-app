"""
Stage a validated dataset to Supabase Storage and update dvc_operations.

NOTE: This script is NOT called by any workflow. Dataset uploads now push
directly to DVC (Google Drive) without Supabase Storage staging. Kept for
reference / potential future local use.

Usage:
    python stage_dataset_to_storage.py \
        --data-dir data/mango \
        --leaf-type mango \
        --dvc-operation-id <uuid>

Env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
import zipfile
import tempfile
from datetime import datetime, timezone

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp', '.tiff', '.tif'}


def collect_metadata(data_dir):
    """Collect file count, size, and class distribution."""
    classes = {}
    total_files = 0
    total_size = 0
    for entry in sorted(os.listdir(data_dir)):
        cls_path = os.path.join(data_dir, entry)
        if not os.path.isdir(cls_path):
            continue
        count = 0
        for f in os.listdir(cls_path):
            fpath = os.path.join(cls_path, f)
            if os.path.isfile(fpath) and os.path.splitext(f)[1].lower() in IMAGE_EXTS:
                count += 1
                total_size += os.path.getsize(fpath)
        classes[entry] = count
        total_files += count
    return {'file_count': total_files, 'total_size': total_size, 'classes': classes}


def create_zip(data_dir, output_path):
    """Create ZIP archive of the dataset directory."""
    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(data_dir):
            for f in files:
                filepath = os.path.join(root, f)
                arcname = os.path.relpath(filepath, os.path.dirname(data_dir))
                zf.write(filepath, arcname)
    return os.path.getsize(output_path)


def upload_to_storage(supabase_url, service_key, bucket, path, filepath):
    """Upload file to Supabase Storage via REST API."""
    with open(filepath, 'rb') as f:
        data = f.read()
    url = f"{supabase_url}/storage/v1/object/{bucket}/{path}"
    req = urllib.request.Request(url, data=data, method='POST')
    req.add_header('apikey', service_key)
    req.add_header('Authorization', f'Bearer {service_key}')
    req.add_header('Content-Type', 'application/zip')
    req.add_header('x-upsert', 'true')
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        print(f"[ERROR] Storage upload failed ({e.code}): {body}", file=sys.stderr)
        raise


def update_dvc_operation(supabase_url, service_key, op_id, status, metadata=None, error_msg=None):
    """Update dvc_operations row via Supabase REST API."""
    body = {'status': status}
    if metadata:
        body['metadata'] = metadata
    if status in ('completed', 'failed', 'staged'):
        body['completed_at'] = datetime.now(timezone.utc).isoformat()
    if error_msg:
        body['error_message'] = error_msg

    encoded_id = urllib.parse.quote(op_id, safe='')
    url = f"{supabase_url}/rest/v1/dvc_operations?id=eq.{encoded_id}"
    data = json.dumps(body).encode('utf-8')
    req = urllib.request.Request(url, data=data, method='PATCH')
    req.add_header('apikey', service_key)
    req.add_header('Authorization', f'Bearer {service_key}')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Prefer', 'return=minimal')
    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        print(f"[WARN] dvc_operations update failed ({e.code}): {body}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description='Stage dataset to Supabase Storage')
    parser.add_argument('--data-dir', required=True, help='Path to validated dataset directory')
    parser.add_argument('--leaf-type', required=True, help='Leaf type identifier')
    parser.add_argument('--dvc-operation-id', default='', help='DVC operation ID for tracking')
    parser.add_argument('--bucket', default='datasets', help='Supabase Storage bucket')
    args = parser.parse_args()

    supabase_url = os.environ.get('SUPABASE_URL', '')
    service_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    if not supabase_url or not service_key:
        print('[ERROR] SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required', file=sys.stderr)
        sys.exit(1)

    if not os.path.isdir(args.data_dir):
        print(f'[ERROR] Data directory not found: {args.data_dir}', file=sys.stderr)
        sys.exit(1)

    # 1. Collect metadata
    metadata = collect_metadata(args.data_dir)
    print(f"Dataset: {metadata['file_count']} files, {metadata['total_size']} bytes")
    for cls, cnt in metadata['classes'].items():
        print(f"  {cls}: {cnt} images")

    if metadata['file_count'] == 0:
        msg = 'No image files found in dataset directory'
        print(f'[ERROR] {msg}', file=sys.stderr)
        if args.dvc_operation_id:
            update_dvc_operation(supabase_url, service_key, args.dvc_operation_id, 'failed', error_msg=msg)
        sys.exit(1)

    # 2. Create ZIP
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    zip_name = f"{args.leaf_type}_staging_{timestamp}.zip"
    zip_path = os.path.join(tempfile.gettempdir(), zip_name)
    zip_size = create_zip(args.data_dir, zip_path)
    print(f"ZIP created: {zip_path} ({zip_size} bytes)")

    # 3. Upload to Supabase Storage
    storage_path = f"{args.leaf_type}/staging/{zip_name}"
    print(f"Uploading to {args.bucket}/{storage_path} ...")
    upload_to_storage(supabase_url, service_key, args.bucket, storage_path, zip_path)
    print(f"Upload complete: {args.bucket}/{storage_path}")

    # 4. Update dvc_operations
    metadata['staging_path'] = storage_path
    metadata['staging_bucket'] = args.bucket
    metadata['zip_size'] = zip_size
    if args.dvc_operation_id:
        update_dvc_operation(supabase_url, service_key, args.dvc_operation_id, 'staged', metadata)
        print(f"dvc_operations {args.dvc_operation_id}: status=staged")

    # 5. Output for GitHub Actions
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
            f.write(f"staging_path={storage_path}\n")
            f.write(f"metadata={json.dumps(metadata)}\n")

    # Cleanup
    os.unlink(zip_path)
    print("Done.")


if __name__ == '__main__':
    main()
