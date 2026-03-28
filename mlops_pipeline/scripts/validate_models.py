"""
AgriKD - Cross-Format Model Validator
========================================
Validates that converted models (ONNX, TFLite) produce the same outputs
as the original PyTorch checkpoint.

Usage (config-driven):
    python validate_models.py --config ../configs/tomato.json

Usage (CLI args):
    python validate_models.py \
        --checkpoint ../../model_checkpoints_student/tomato_student.pth \
        --onnx ../../models/tomato/tomato_student.onnx \
        --tflite ../../models/tomato/tomato_student.tflite \
        --num-classes 10
"""

import argparse
import os
import sys

import numpy as np
import torch

# Add scripts directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_definition import load_student_from_checkpoint, load_leaf_config


def run_pytorch_inference(checkpoint_path: str, num_classes: int, input_data: np.ndarray) -> np.ndarray:
    """Run inference with PyTorch model."""
    model = load_student_from_checkpoint(checkpoint_path, num_classes)
    with torch.no_grad():
        output = model(torch.from_numpy(input_data)).numpy()
    return output


def run_onnx_inference(onnx_path: str, input_data: np.ndarray) -> np.ndarray:
    """Run inference with ONNX Runtime."""
    import onnxruntime as ort
    session = ort.InferenceSession(onnx_path)
    output = session.run(None, {"input": input_data})[0]
    return output


def run_tflite_inference(tflite_path: str, input_data: np.ndarray) -> np.ndarray:
    """Run inference with TFLite interpreter."""
    import tensorflow as tf
    
    interpreter = tf.lite.Interpreter(model_path=tflite_path)
    interpreter.allocate_tensors()
    
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    
    # Determine if TFLite model expects NHWC format
    tflite_input_shape = input_details[0]['shape']
    
    # If TFLite expects NHWC (batch, H, W, C) but our input is NCHW (batch, C, H, W)
    if len(tflite_input_shape) == 4 and tflite_input_shape[-1] == 3:
        # Convert NCHW -> NHWC
        tflite_input = np.transpose(input_data, (0, 2, 3, 1))
    else:
        tflite_input = input_data
    
    # Resize input tensor if needed
    if not np.array_equal(tflite_input.shape, tflite_input_shape):
        interpreter.resize_tensor_input(input_details[0]['index'], list(tflite_input.shape))
        interpreter.allocate_tensors()
    
    interpreter.set_tensor(input_details[0]['index'], tflite_input.astype(np.float32))
    interpreter.invoke()
    output = interpreter.get_tensor(output_details[0]['index'])
    
    return output


def compare_outputs(name_a: str, output_a: np.ndarray, name_b: str, output_b: np.ndarray, atol: float = 1e-4):
    """Compare two model outputs and print results."""
    max_diff = np.max(np.abs(output_a - output_b))
    mean_diff = np.mean(np.abs(output_a - output_b))
    
    passed = max_diff < atol
    status = "OK PASS" if passed else "FAIL"
    
    print(f"  {name_a} vs {name_b}:")
    print(f"    Max diff:  {max_diff:.8f}")
    print(f"    Mean diff: {mean_diff:.8f}")
    print(f"    Status:    [{status}] (atol={atol})")
    
    return passed


def validate_models(
    checkpoint_path: str,
    onnx_path: str = None,
    tflite_path: str = None,
    num_classes: int = 10,
    num_samples: int = 5,
    atol: float = 1e-4,
    tflite_atol: float = 5e-3,
):
    """
    Validate all model formats produce consistent outputs.

    Args:
        checkpoint_path: Path to original .pth checkpoint.
        onnx_path: Path to .onnx model (optional).
        tflite_path: Path to .tflite model (optional).
        num_classes: Number of output classes.
        num_samples: Number of random inputs to test.
        atol: Absolute tolerance for ONNX comparison.
        tflite_atol: Absolute tolerance for TFLite comparison (higher due to conversion precision loss).
    """
    print("\n" + "=" * 60)
    print("  AgriKD: Cross-Format Model Validation")
    print("=" * 60)

    # Load PyTorch model once — reuse for all samples to keep BatchNorm stats consistent
    model = load_student_from_checkpoint(checkpoint_path, num_classes)

    all_passed = True

    for i in range(num_samples):
        print(f"\n--- Sample {i + 1}/{num_samples} ---")

        # Generate random input (NCHW format)
        np.random.seed(42 + i)
        input_data = np.random.randn(1, 3, 224, 224).astype(np.float32)

        # PyTorch reference
        with torch.no_grad():
            pytorch_output = model(torch.from_numpy(input_data)).numpy()
        print(f"  PyTorch output: {pytorch_output[0][:5]}... (showing first 5)")

        # ONNX comparison
        if onnx_path and os.path.exists(onnx_path):
            onnx_output = run_onnx_inference(onnx_path, input_data)
            if not compare_outputs("PyTorch", pytorch_output, "ONNX", onnx_output, atol):
                all_passed = False

        # TFLite comparison (uses higher tolerance due to NCHW→NHWC + FlatBuffer precision)
        if tflite_path and os.path.exists(tflite_path):
            tflite_output = run_tflite_inference(tflite_path, input_data)
            if not compare_outputs("PyTorch", pytorch_output, "TFLite", tflite_output, tflite_atol):
                all_passed = False

    # Summary
    print(f"\n{'=' * 60}")
    if all_passed:
        print(f"  [OK] ALL VALIDATIONS PASSED ({num_samples} samples)")
    else:
        print(f"  [FAIL] SOME VALIDATIONS FAILED - check outputs above")
    print(f"{'=' * 60}")

    return all_passed


def main():
    parser = argparse.ArgumentParser(
        description="Validate AgriKD model conversions across formats"
    )
    parser.add_argument(
        "--config", default=None,
        help="Path to leaf config JSON (auto-fills checkpoint, onnx, tflite, num-classes)"
    )
    parser.add_argument(
        "--checkpoint", default=None,
        help="Path to the original .pth checkpoint"
    )
    parser.add_argument(
        "--onnx", default=None,
        help="Path to the .onnx model"
    )
    parser.add_argument(
        "--tflite", default=None,
        help="Path to the .tflite model"
    )
    parser.add_argument(
        "--num-classes", type=int, default=None,
        help="Number of output classes"
    )
    parser.add_argument(
        "--num-samples", type=int, default=5,
        help="Number of random samples to test (default: 5)"
    )
    parser.add_argument(
        "--atol", type=float, default=1e-4,
        help="Absolute tolerance for comparison (default: 1e-4)"
    )

    args = parser.parse_args()

    if args.config:
        cfg = load_leaf_config(args.config)
        if args.checkpoint is None:
            args.checkpoint = cfg["_paths"]["checkpoint"]
        if args.num_classes is None:
            args.num_classes = cfg["num_classes"]
        if args.onnx is None:
            onnx_path = cfg["_paths"]["onnx"]
            if os.path.exists(onnx_path):
                args.onnx = onnx_path
        if args.tflite is None:
            tflite_path = cfg["_paths"]["tflite"]
            if os.path.exists(tflite_path):
                args.tflite = tflite_path

    if not args.checkpoint or args.num_classes is None:
        parser.error("Either --config or --checkpoint and --num-classes are required")

    if not args.onnx and not args.tflite:
        print("[FAIL] At least one of --onnx or --tflite must exist/be provided")
        sys.exit(1)

    passed = validate_models(
        args.checkpoint, args.onnx, args.tflite,
        args.num_classes, args.num_samples, args.atol
    )
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
