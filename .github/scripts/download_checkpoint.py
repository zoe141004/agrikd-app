"""Download and validate a .pth checkpoint from Supabase Storage.

Used by the model-pipeline CI workflow.  Replaces the equivalent
bash logic for better testability and clearer error messages.

Required environment variables:
    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, MODEL_URL_INPUT,
    LEAF_TYPE, VERSION
"""

import os
import re
import sys
from urllib.parse import urlparse

import requests

# ── Validation helpers ──────────────────────────────────────────────

_LEAF_PATTERN = re.compile(r"^[a-z_]+$")
_VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


def _env(name: str) -> str:
    val = os.environ.get(name, "")
    if not val:
        sys.exit(f"[ERROR] Missing environment variable: {name}")
    return val


def _validate_inputs(leaf_type: str, version: str) -> None:
    if not _LEAF_PATTERN.match(leaf_type):
        sys.exit(f"[ERROR] Invalid leaf_type: {leaf_type} (must be lowercase letters and underscores)")
    if not _VERSION_PATTERN.match(version):
        sys.exit(f"[ERROR] Invalid version: {version} (must be semver like 1.2.3)")


def _validate_url(url: str, supabase_url: str) -> None:
    parsed = urlparse(url)
    allowed = urlparse(supabase_url).hostname
    if parsed.scheme != "https":
        sys.exit(f"[ERROR] URL must be HTTPS: {url}")
    if parsed.hostname != allowed:
        sys.exit(f"[ERROR] URL host '{parsed.hostname}' != Supabase host '{allowed}'")
    if not parsed.path.startswith("/storage/"):
        sys.exit(f"[ERROR] URL must point to Supabase storage: {url}")


# ── Download ────────────────────────────────────────────────────────

def _download(url: str, dest: str, service_key: str, supabase_url: str) -> None:
    """Try public URL first, fall back to authenticated."""
    resp = requests.get(url, timeout=120, allow_redirects=True)
    if resp.status_code != 200:
        print(f"Public download failed ({resp.status_code}), trying authenticated...")
        storage_path = url.split("storage/v1/object/public/", 1)
        if len(storage_path) != 2:
            sys.exit(f"[ERROR] Could not parse storage path from URL: {url}")
        auth_url = f"{supabase_url}/storage/v1/object/authenticated/{storage_path[1]}"
        resp = requests.get(
            auth_url,
            headers={
                "apikey": service_key,
                "Authorization": f"Bearer {service_key}",
            },
            timeout=120,
        )
    if resp.status_code != 200:
        sys.exit(f"[ERROR] Download failed with HTTP {resp.status_code}")

    ct = resp.headers.get("content-type", "")
    if "text/html" in ct or "text/plain" in ct:
        sys.exit(f"[ERROR] Server returned {ct} instead of binary — likely an error page")

    with open(dest, "wb") as f:
        f.write(resp.content)


def _validate_file(path: str) -> None:
    size = os.path.getsize(path)
    print(f"Downloaded: {size} bytes")
    if size < 10_000:
        sys.exit(f"[ERROR] File too small ({size} bytes), likely not a valid checkpoint")
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic not in (b"PK", b"\x89P"):
        sys.exit(f"[ERROR] Not a valid PyTorch checkpoint (magic: {magic.hex()})")


# ── Main ────────────────────────────────────────────────────────────

def main() -> None:
    supabase_url = _env("SUPABASE_URL")
    service_key = _env("SUPABASE_SERVICE_ROLE_KEY")
    model_url = _env("MODEL_URL_INPUT")
    leaf_type = _env("LEAF_TYPE")
    version = _env("VERSION")

    _validate_inputs(leaf_type, version)
    _validate_url(model_url, supabase_url)

    os.makedirs("model_checkpoints_student", exist_ok=True)
    dest = f"model_checkpoints_student/{leaf_type}_student.pth"
    print(f"Model URL: {model_url}")

    # If URL points to .tflite, derive .pth URL by convention
    if model_url.endswith(".tflite"):
        base = model_url.rsplit("/", 1)[0]
        model_url = f"{base}/{leaf_type}_v{version}_checkpoint.pth"
        _validate_url(model_url, supabase_url)
        print(f"Derived .pth URL: {model_url}")

    _download(model_url, dest, service_key, supabase_url)
    _validate_file(dest)
    print("Checkpoint download and validation OK")


if __name__ == "__main__":
    main()
