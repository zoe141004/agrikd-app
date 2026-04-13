#!/bin/bash
# ─────────────────────────────────────────────────────────────
# AgriKD GUI Launcher
# ─────────────────────────────────────────────────────────────
# Always uses system Python (/usr/bin/python3) which has JetPack
# TensorRT and PyCUDA bindings.  Safe to call from any shell
# environment (conda, virtualenv, etc.).
#
# Usage:
#   ./run_gui.sh                            # default config
#   ./run_gui.sh --config /path/config.json # custom config
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine install root (script lives in /opt/agrikd/ or repo/jetson/)
if [ -d "$SCRIPT_DIR/app" ] && [ -f "$SCRIPT_DIR/app/gui_app.py" ]; then
    INSTALL_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/gui_app.py" ]; then
    INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
else
    echo "[ERROR] Cannot locate gui_app.py relative to $SCRIPT_DIR"
    exit 1
fi

SYSTEM_PYTHON="/usr/bin/python3"

if [ ! -x "$SYSTEM_PYTHON" ]; then
    echo "[ERROR] System Python not found at $SYSTEM_PYTHON"
    echo "  Ensure Python 3 is installed (apt install python3)."
    exit 1
fi

exec "$SYSTEM_PYTHON" "$INSTALL_DIR/app/gui_app.py" \
    --config "$INSTALL_DIR/config/config.json" \
    "$@"
