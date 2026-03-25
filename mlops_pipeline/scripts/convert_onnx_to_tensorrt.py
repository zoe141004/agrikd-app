"""
AgriKD - ONNX to TensorRT Converter
======================================
Converts an ONNX model to TensorRT engine format for NVIDIA Jetson devices.

IMPORTANT: TensorRT conversion MUST run on the target Jetson device because
the engine file is hardware-specific (GPU architecture, CUDA version, etc).

This script provides two methods:
  1. trtexec CLI (recommended) - uses NVIDIA's built-in tool
  2. Python TensorRT API (fallback) - programmatic conversion

Prerequisites (on Jetson):
    - JetPack SDK installed (includes TensorRT)
    - ONNX model file accessible on the Jetson filesystem

Usage (on Jetson):
    # Method 1: Using trtexec CLI (recommended)
    python convert_onnx_to_tensorrt.py \
        --input /path/to/models/tomato/tomato_student.onnx \
        --output /path/to/models/tomato/tomato_student.engine \
        --method trtexec

    # Method 2: Using Python API
    python convert_onnx_to_tensorrt.py \
        --input /path/to/models/tomato/tomato_student.onnx \
        --output /path/to/models/tomato/tomato_student.engine \
        --method python

    # With FP16 precision (faster inference on Jetson)
    python convert_onnx_to_tensorrt.py \
        --input /path/to/models/tomato/tomato_student.onnx \
        --output /path/to/models/tomato/tomato_student.engine \
        --method trtexec \
        --fp16
"""

import argparse
import os
import subprocess
import sys


def convert_with_trtexec(
    input_path: str,
    output_path: str,
    fp16: bool = True,
    workspace_mb: int = 1024,
) -> str:
    """
    Convert ONNX to TensorRT engine using trtexec CLI.
    
    trtexec is included with TensorRT installation on Jetson (JetPack SDK).
    This is the recommended method as it handles optimization automatically.
    
    Args:
        input_path: Path to input .onnx file.
        output_path: Path to save .engine file.
        fp16: Enable FP16 precision (recommended for Jetson).
        workspace_mb: Max workspace size in MB for TensorRT builder.
        
    Returns:
        Path to the saved engine file.
    """
    print("\n" + "=" * 60)
    print("  AgriKD: ONNX -> TensorRT (trtexec)")
    print("=" * 60)
    
    # Build trtexec command
    cmd = [
        "trtexec",
        f"--onnx={input_path}",
        f"--saveEngine={output_path}",
        f"--workspace={workspace_mb}",
        "--explicitBatch",
    ]
    
    if fp16:
        cmd.append("--fp16")
        print("[...] FP16 precision enabled")
    
    # Create output directory
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    
    print(f"[...] Running: {' '.join(cmd)}")
    print(f"[...] This may take several minutes on Jetson...\n")
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=600,  # 10 minute timeout
        )
        
        if result.returncode == 0:
            file_size_mb = os.path.getsize(output_path) / (1024 * 1024)
            print(f"\n[OK] TensorRT engine saved: {output_path}")
            print(f"    File size: {file_size_mb:.2f} MB")
        else:
            print(f"\n[FAIL] trtexec failed!")
            print(f"    stderr: {result.stderr[:500]}")
            sys.exit(1)
            
    except FileNotFoundError:
        print(f"\n[FAIL] 'trtexec' not found!")
        print(f"    Make sure TensorRT is installed (JetPack SDK)")
        print(f"    Or try: --method python")
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"\n[FAIL] trtexec timed out after 10 minutes")
        sys.exit(1)
    
    print("=" * 60)
    return output_path


def convert_with_python_api(
    input_path: str,
    output_path: str,
    fp16: bool = True,
    workspace_mb: int = 1024,
) -> str:
    """
    Convert ONNX to TensorRT engine using Python TensorRT API.
    
    Fallback method if trtexec is not available.
    Requires: pip install tensorrt (on Jetson with JetPack)
    
    Args:
        input_path: Path to input .onnx file.
        output_path: Path to save .engine file.
        fp16: Enable FP16 precision.
        workspace_mb: Max workspace size in MB.
        
    Returns:
        Path to the saved engine file.
    """
    print("\n" + "=" * 60)
    print("  AgriKD: ONNX -> TensorRT (Python API)")
    print("=" * 60)
    
    try:
        import tensorrt as trt
    except ImportError:
        print("[FAIL] TensorRT Python package not installed!")
        print("    On Jetson: sudo apt-get install python3-libnvinfer")
        print("    Or try: --method trtexec")
        sys.exit(1)
    
    TRT_LOGGER = trt.Logger(trt.Logger.WARNING)
    
    print(f"[...] TensorRT version: {trt.__version__}")
    print(f"[...] Loading ONNX model: {input_path}")
    
    # Create builder and network
    builder = trt.Builder(TRT_LOGGER)
    network = builder.create_network(
        1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH)
    )
    parser = trt.OnnxParser(network, TRT_LOGGER)
    
    # Parse ONNX model
    with open(input_path, "rb") as f:
        if not parser.parse(f.read()):
            for i in range(parser.num_errors):
                print(f"    Parse error: {parser.get_error(i)}")
            sys.exit(1)
    
    print(f"[OK] ONNX model parsed successfully")
    
    # Configure builder
    config = builder.create_builder_config()
    config.max_workspace_size = workspace_mb * (1 << 20)  # MB to bytes
    
    if fp16 and builder.platform_has_fast_fp16:
        config.set_flag(trt.BuilderFlag.FP16)
        print(f"[...] FP16 precision enabled")
    elif fp16:
        print(f"[WARN] FP16 requested but not supported on this platform")
    
    # Build engine
    print(f"[...] Building TensorRT engine (this may take several minutes)...")
    engine = builder.build_engine(network, config)
    
    if engine is None:
        print(f"[FAIL] Engine build failed!")
        sys.exit(1)
    
    # Save engine
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(engine.serialize())
    
    file_size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\n[OK] TensorRT engine saved: {output_path}")
    print(f"    File size: {file_size_mb:.2f} MB")
    print("=" * 60)
    
    return output_path


def print_jetson_instructions(onnx_path: str, engine_path: str):
    """Print manual instructions for running on Jetson."""
    print("\n" + "=" * 60)
    print("  INSTRUCTIONS: Run on Jetson Device")
    print("=" * 60)
    print(f"""
If this script is not run on Jetson, follow these steps:

1. Copy the ONNX model to your Jetson device:
   scp {onnx_path} user@jetson-ip:/home/user/agrikd/models/

2. SSH into the Jetson:
   ssh user@jetson-ip

3. Convert using trtexec (included in JetPack):
   trtexec --onnx=/home/user/agrikd/models/{os.path.basename(onnx_path)} \\
           --saveEngine=/home/user/agrikd/models/{os.path.basename(engine_path)} \\
           --fp16 \\
           --workspace=1024

4. Verify the engine:
   trtexec --loadEngine=/home/user/agrikd/models/{os.path.basename(engine_path)} \\
           --batch=1

5. Copy the engine back (if needed):
   scp user@jetson-ip:/home/user/agrikd/models/{os.path.basename(engine_path)} .
""")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="Convert AgriKD ONNX model to TensorRT engine (run on Jetson)"
    )
    parser.add_argument(
        "--input", required=True,
        help="Path to the input .onnx model"
    )
    parser.add_argument(
        "--output", required=True,
        help="Output path for the .engine file"
    )
    parser.add_argument(
        "--method", choices=["trtexec", "python", "instructions"],
        default="trtexec",
        help="Conversion method (default: trtexec)"
    )
    parser.add_argument(
        "--fp16", action="store_true", default=True,
        help="Enable FP16 precision (default: True)"
    )
    parser.add_argument(
        "--no-fp16", action="store_true",
        help="Disable FP16 precision"
    )
    parser.add_argument(
        "--workspace", type=int, default=1024,
        help="Max workspace size in MB (default: 1024)"
    )
    
    args = parser.parse_args()
    
    fp16 = args.fp16 and not args.no_fp16
    
    if args.method == "instructions":
        print_jetson_instructions(args.input, args.output)
    elif args.method == "trtexec":
        convert_with_trtexec(args.input, args.output, fp16, args.workspace)
    elif args.method == "python":
        convert_with_python_api(args.input, args.output, fp16, args.workspace)


if __name__ == "__main__":
    main()
