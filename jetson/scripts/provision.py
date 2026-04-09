#!/usr/bin/env python3
"""
AgriKD Zero-Touch Provisioning Script
======================================
Provisions a Jetson device using a one-time token from the Admin Dashboard.

Usage:
    python3 scripts/provision.py agrikd://eyJhbGc...           # paste token
    python3 scripts/provision.py --file /media/usb/.token       # read from file
    python3 scripts/provision.py --force agrikd://eyJhbGc...    # re-register active device
"""

import argparse
import base64
import hashlib
import json
import os
import platform
import socket
import stat
import sys
import time

import requests


# ---------------------------------------------------------------------------
# Hardware fingerprinting
# ---------------------------------------------------------------------------

def _read_file(path):
    """Read a file and return stripped content, or None."""
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def _get_mac_address():
    """Get MAC address from the first available network interface."""
    for iface in ("eth0", "wlan0", "enp0s3", "docker0"):
        mac = _read_file(f"/sys/class/net/{iface}/address")
        if mac and mac != "00:00:00:00:00:00":
            return mac
    # Fallback: uuid-based MAC
    import uuid
    return ":".join(f"{uuid.getnode():012x}"[i:i+2] for i in range(0, 12, 2))


def _get_serial():
    """Get board serial with multi-level fallback.

    Fallback chain:
      1. Jetson device-tree serial (/sys/firmware/devicetree/base/serial-number)
      2. DBUS Machine ID (/etc/machine-id)  — unique per OS install
      3. Root filesystem UUID (blkid /)      — unique per disk
      4. Fail: exit with error (hw_id must never be empty/duplicate)
    """
    # 1. Jetson device-tree serial
    serial = _read_file("/sys/firmware/devicetree/base/serial-number")
    if serial:
        serial = serial.rstrip("\x00").strip()
        # Guard: some Jetson boards return empty or all-zeros
        if serial and serial != "0" * len(serial):
            return serial

    # 2. DBUS Machine ID (stable per OS install)
    machine_id = _read_file("/etc/machine-id")
    if machine_id and machine_id.strip():
        return machine_id.strip()

    # 3. Root filesystem UUID via blkid
    try:
        import subprocess
        result = subprocess.run(
            ["blkid", "-s", "UUID", "-o", "value", "/dev/mmcblk0p1"],
            capture_output=True, text=True, timeout=5,
        )
        disk_uuid = result.stdout.strip()
        if disk_uuid:
            return disk_uuid
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass

    # 4. Fatal: cannot generate unique hw_id
    print("ERROR: Cannot determine unique hardware identity.")
    print("  Checked: device-tree serial, /etc/machine-id, disk UUID")
    print("  Please create /etc/machine-id: systemd-machine-id-setup")
    sys.exit(1)


def get_hardware_info():
    """Collect hardware fingerprint and info."""
    mac = _get_mac_address()
    serial = _get_serial()
    hw_id = hashlib.sha256(f"{mac}:{serial}".encode()).hexdigest()[:32]
    hostname = socket.gethostname()

    jetpack = _read_file("/etc/nv_tegra_release")
    if jetpack:
        jetpack = jetpack.split("\n")[0].strip()

    hw_info = {
        "hostname": hostname,
        "platform": platform.machine(),
        "python": platform.python_version(),
        "mac": mac,
        "serial": serial,
    }
    if jetpack:
        hw_info["jetpack"] = jetpack

    return hw_id, hostname, hw_info


# ---------------------------------------------------------------------------
# Token parsing
# ---------------------------------------------------------------------------

def parse_token(raw):
    """Decode agrikd:// provisioning token."""
    prefix = "agrikd://"
    if not raw.startswith(prefix):
        print(f"ERROR: Token must start with '{prefix}'")
        sys.exit(1)

    encoded = raw[len(prefix):]
    # Add padding if needed
    padding = 4 - len(encoded) % 4
    if padding != 4:
        encoded += "=" * padding

    try:
        decoded = base64.urlsafe_b64decode(encoded)
        data = json.loads(decoded)
    except Exception as e:
        print(f"ERROR: Cannot decode token: {e}")
        sys.exit(1)

    required = ("url", "key", "tid")
    for key in required:
        if key not in data:
            print(f"ERROR: Token missing required field: {key}")
            sys.exit(1)

    # Check expiry
    exp = data.get("exp", 0)
    if exp and time.time() > exp:
        print("ERROR: Provisioning token has expired. Ask Admin for a new one.")
        sys.exit(1)

    return data


# ---------------------------------------------------------------------------
# Supabase API helpers
# ---------------------------------------------------------------------------

def supabase_get(url, key, path, params=None):
    """GET request to Supabase REST API."""
    resp = requests.get(
        f"{url}/rest/v1/{path}",
        headers={"apikey": key, "Authorization": f"Bearer {key}"},
        params=params or {},
        timeout=15,
    )
    return resp


def supabase_post(url, key, path, body):
    """POST request to Supabase REST API."""
    resp = requests.post(
        f"{url}/rest/v1/{path}",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        },
        json=body,
        timeout=15,
    )
    return resp


def supabase_patch(url, key, path, body, params=None, extra_headers=None):
    """PATCH request to Supabase REST API."""
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
    if extra_headers:
        headers.update(extra_headers)
    resp = requests.patch(
        f"{url}/rest/v1/{path}",
        headers=headers,
        params=params or {},
        json=body,
        timeout=15,
    )
    return resp


# ---------------------------------------------------------------------------
# Main provisioning flow
# ---------------------------------------------------------------------------

def provision(token_data, force=False):
    """Execute the provisioning flow."""
    url = token_data["url"]
    key = token_data["key"]
    tid = token_data["tid"]

    print("AgriKD Zero-Touch Provisioning")
    print("=" * 40)

    # 1. Validate token on server
    print("[1/6] Validating provisioning token...")
    resp = supabase_get(url, key, "provisioning_tokens", {
        "id": f"eq.{tid}",
        "used_at": "is.null",
        "select": "id,expires_at",
    })
    if resp.status_code != 200 or not resp.json():
        print("ERROR: Invalid or already-used provisioning token.")
        sys.exit(1)
    print("  Token valid.")

    # 2. Detect hardware
    print("[2/6] Detecting hardware...")
    hw_id, hostname, hw_info = get_hardware_info()
    print(f"  Hostname: {hostname}")
    print(f"  HW ID:    {hw_id}")
    print(f"  Platform: {hw_info['platform']}")

    # 3. Check existing device
    print("[3/6] Checking device registration...")
    resp = supabase_get(url, key, "devices", {
        "hw_id": f"eq.{hw_id}",
        "select": "id,status,device_token",
    })
    existing = resp.json() if resp.status_code == 200 else []

    device_id = None
    device_token = None

    if existing:
        device = existing[0]
        status = device["status"]
        if status in ("online", "offline", "assigned") and not force:
            print(f"ERROR: Device already registered with status '{status}'.")
            print("  Use --force to re-register, or ask Admin to 'Decommission' first.")
            sys.exit(1)

        # Re-register: update existing record
        print(f"  Existing device (status={status}), re-registering...")
        # patch_body defined inline below — anon key + existing token header
        resp = supabase_patch(url, key, "devices", {
            "hostname": hostname,
            "hw_info": hw_info,
            "status": "unassigned",
            "user_id": None,
            "reported_config": None,
            "config_version": 0,
        }, params={"hw_id": f"eq.{hw_id}"}, extra_headers={
            "X-Device-Token": device["device_token"],
        })

        if resp.status_code not in (200, 201):
            print(f"ERROR: Failed to re-register: HTTP {resp.status_code}")
            print(f"  {resp.text[:200]}")
            sys.exit(1)

        updated = resp.json()
        if updated:
            device_id = updated[0]["id"]
            device_token = updated[0]["device_token"]
    else:
        # New device: INSERT
        print("  New device, registering...")
        resp = supabase_post(url, key, "devices", {
            "hw_id": hw_id,
            "hostname": hostname,
            "status": "unassigned",
            "hw_info": hw_info,
        })
        if resp.status_code not in (200, 201):
            print(f"ERROR: Failed to register: HTTP {resp.status_code}")
            print(f"  {resp.text[:200]}")
            sys.exit(1)

        created = resp.json()
        if created:
            device_id = created[0]["id"]
            device_token = created[0]["device_token"]

    if not device_id or not device_token:
        print("ERROR: Could not obtain device ID or token from server.")
        sys.exit(1)

    print(f"  Registered as device #{device_id}")

    # 4. Claim provisioning token
    print("[4/6] Claiming provisioning token...")
    from datetime import datetime, timezone
    resp = supabase_patch(url, key, "provisioning_tokens", {
        "used_at": datetime.now(timezone.utc).isoformat(),
        "used_by_hw_id": hw_id,
        "device_id": device_id,
    }, params={"id": f"eq.{tid}"})

    if resp.status_code not in (200, 204):
        print(f"WARNING: Could not claim token (HTTP {resp.status_code}). Continuing anyway.")

    # 5. Generate config.json
    print("[5/6] Generating config.json...")
    config_path = os.path.join("config", "config.json")
    template_path = os.path.join("config", "config.example.json")

    if os.path.exists(config_path):
        # Merge: only update sync section, keep existing config
        with open(config_path, "r") as f:
            config = json.load(f)
        config["sync"]["supabase_url"] = url
        config["sync"]["supabase_key"] = key
        print("  Updated existing config.json (sync section only)")
    elif os.path.exists(template_path):
        with open(template_path, "r") as f:
            config = json.load(f)
        config["sync"]["supabase_url"] = url
        config["sync"]["supabase_key"] = key
        print("  Created config.json from template")
    else:
        config = {
            "sync": {"supabase_url": url, "supabase_key": key,
                     "batch_size": 50, "interval_seconds": 300},
            "camera": {"source": 0, "width": 640, "height": 480, "mode": "manual"},
            "server": {"host": "0.0.0.0", "port": 8080, "api_key": ""},
            "database": {"path": "data/agrikd_jetson.db"},
            "logging": {"level": "INFO", "file": "logs/agrikd.log",
                        "max_bytes": 104857600, "backup_count": 5},
        }
        print("  Created minimal config.json")

    os.makedirs(os.path.dirname(config_path) or ".", exist_ok=True)
    with open(config_path, "w") as f:
        json.dump(config, f, indent=4)

    # Fix 2.7: Protect config.json (contains Supabase anon key)
    try:
        os.chmod(config_path, stat.S_IRUSR | stat.S_IWUSR)  # 600
    except OSError:
        pass  # Windows or permission issue

    # 6. Write device_state.json
    print("[6/6] Writing device state...")
    state_path = os.path.join("data", "device_state.json")
    os.makedirs(os.path.dirname(state_path), exist_ok=True)

    state = {
        "device_token": str(device_token),
        "device_id": device_id,
        "hw_id": hw_id,
        "user_id": None,
        "provisioned_at": datetime.now(timezone.utc).isoformat(),
        "config_version_applied": 0,
        "desired_config": None,
        "reported_config": None,
    }
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)

    # Protect file permissions (Unix only)
    try:
        os.chmod(state_path, stat.S_IRUSR | stat.S_IWUSR)  # 600
    except OSError:
        pass  # Windows or permission issue

    print()
    print("=" * 40)
    print(f"Provisioned as '{hostname}' (hw_id: {hw_id[:12]}...)")
    print(f"Device ID: {device_id}")
    print()
    print("Next steps:")
    print("  1. Start the service:  systemctl start agrikd")
    print("  2. Ask Admin to assign this device to a user on the Dashboard.")
    print("     Admin Dashboard -> Devices -> Select this device -> Assign User")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="AgriKD Zero-Touch Provisioning",
        epilog="Get a provisioning token from your Admin Dashboard.",
    )
    parser.add_argument(
        "token",
        nargs="?",
        help="Provisioning token (agrikd://...)",
    )
    parser.add_argument(
        "--file", "-f",
        help="Read token from file instead of argument",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force re-register an active device",
    )
    args = parser.parse_args()

    # Read token
    raw_token = None
    if args.file:
        if not os.path.exists(args.file):
            print(f"ERROR: Token file not found: {args.file}")
            sys.exit(1)
        with open(args.file, "r") as f:
            raw_token = f.read().strip()
    elif args.token:
        raw_token = args.token.strip()
    else:
        parser.print_help()
        sys.exit(1)

    token_data = parse_token(raw_token)
    provision(token_data, force=args.force)


if __name__ == "__main__":
    main()
