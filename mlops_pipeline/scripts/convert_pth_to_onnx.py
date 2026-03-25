"""
AgriKD - PyTorch to ONNX Converter
====================================
Converts a KD student checkpoint (.pth) to ONNX format.

The exported ONNX model serves as the universal intermediate format:
  - Jetson: ONNX -> TensorRT (via trtexec on device)
  - Mobile: ONNX -> TFLite (via onnx2tf)
  - Fallback: ONNX Runtime can run ONNX directly on both platforms

Usage (config-driven):
    python convert_pth_to_onnx.py --config ../configs/tomato.json

Usage (CLI args):
    python convert_pth_to_onnx.py \
        --checkpoint ../../model_checkpoints_student/tomato_student.pth \
        --num-classes 10 \
        --output ../../models/tomato/tomato_student.onnx
"""

import argparse
import os
import sys

import torch
import onnx
import onnxruntime as ort
import numpy as np

# Add scripts directory to path for model_definition import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_definition import load_student_from_checkpoint, load_leaf_config


def convert_pth_to_onnx(
    checkpoint_path: str,
    num_classes: int,
    output_path: str,
    opset_version: int = 17,
    input_size: tuple = (1, 3, 224, 224),
) -> str:
    """
    Convert a PyTorch student checkpoint to ONNX format.
    
    Args:
        checkpoint_path: Path to the .pth checkpoint.
        num_classes: Number of output classes.
        output_path: Path to save the .onnx file.
        opset_version: ONNX opset version (13 for broad compatibility).
        input_size: Model input tensor shape.
        
    Returns:
        Path to the saved ONNX file.
    """
    # Step 1: Load PyTorch model
    print("\n" + "=" * 60)
    print("  AgriKD: PyTorch -> ONNX Conversion")
    print("=" * 60)
    
    model = load_student_from_checkpoint(checkpoint_path, num_classes)
    model.eval()
    
    # Step 2: Create dummy input for tracing
    dummy_input = torch.randn(*input_size)
    
    # Step 3: Create output directory
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    
    # Step 4: Export to ONNX
    print(f"\n[...] Exporting to ONNX (opset={opset_version})...")
    torch.onnx.export(
        model,
        dummy_input,
        output_path,
        export_params=True,
        opset_version=opset_version,
        do_constant_folding=True,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={
            "input": {0: "batch_size"},
            "output": {0: "batch_size"},
        },
    )
    
    # Step 5: Validate ONNX model
    print(f"[...] Validating ONNX model...")
    onnx_model = onnx.load(output_path)
    onnx.checker.check_model(onnx_model)
    print(f"[OK] ONNX model validated successfully!")
    
    # Step 6: Verify with ONNX Runtime
    print(f"[...] Verifying with ONNX Runtime...")
    ort_session = ort.InferenceSession(output_path)
    
    # Run inference with same dummy input
    with torch.no_grad():
        pytorch_output = model(dummy_input).numpy()
    
    ort_inputs = {"input": dummy_input.numpy()}
    ort_output = ort_session.run(None, ort_inputs)[0]
    
    # Compare outputs
    max_diff = np.max(np.abs(pytorch_output - ort_output))
    print(f"    Max output difference (PyTorch vs ONNX): {max_diff:.8f}")
    
    if max_diff < 1e-5:
        print(f"[OK] Outputs match within tolerance (atol=1e-5)")
    else:
        print(f"[WARN] Outputs differ by {max_diff:.8f} - check for numerical issues")
    
    # File size info
    file_size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\n[OK] ONNX model saved: {output_path}")
    print(f"    File size: {file_size_mb:.2f} MB")
    print("=" * 60)
    
    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="Convert AgriKD student checkpoint (.pth) to ONNX format"
    )
    parser.add_argument(
        "--config", default=None,
        help="Path to leaf config JSON (auto-fills checkpoint, num-classes, output)"
    )
    parser.add_argument(
        "--checkpoint", default=None,
        help="Path to the .pth checkpoint file"
    )
    parser.add_argument(
        "--num-classes", type=int, default=None,
        help="Number of output classes for this model"
    )
    parser.add_argument(
        "--output", default=None,
        help="Output path for the .onnx file"
    )
    parser.add_argument(
        "--opset", type=int, default=17,
        help="ONNX opset version (default: 17)"
    )

    args = parser.parse_args()

    # Load defaults from config JSON if provided
    input_size = (1, 3, 224, 224)
    if args.config:
        cfg = load_leaf_config(args.config)
        if args.checkpoint is None:
            args.checkpoint = cfg["_paths"]["checkpoint"]
        if args.num_classes is None:
            args.num_classes = cfg["num_classes"]
        if args.output is None:
            args.output = cfg["_paths"]["onnx"]
        h, w = cfg["input_size"]
        input_size = (1, 3, h, w)

    # Validate required args
    if not args.checkpoint or args.num_classes is None or not args.output:
        parser.error("Either --config or all of --checkpoint, --num-classes, --output are required")

    convert_pth_to_onnx(args.checkpoint, args.num_classes, args.output, args.opset, input_size)


if __name__ == "__main__":
    main()
