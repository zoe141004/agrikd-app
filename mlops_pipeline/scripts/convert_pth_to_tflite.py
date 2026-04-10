"""
AgriKD - PyTorch to TFLite Direct Conversion
============================================
Converts a PyTorch student model directly to TFLite format using `ai-edge-torch`.
This eliminates the need for ONNX and avoids TensorFlow/Keras environment conflicts.

Usage (config-driven):
    python convert_pth_to_tflite.py --config ../configs/tomato.json

Usage (CLI args):
    python convert_pth_to_tflite.py \
        --checkpoint ../../model_checkpoints_student/tomato_student.pth \
        --num-classes 10 --output ../../models/tomato/tomato_student.tflite
"""

import argparse
import os
import time

import torch
import torchvision
import numpy as np
import logging

# Suppress annoying TF/Torch logs
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'

logger = logging.getLogger(__name__)

try:
    import ai_edge_torch
except ImportError:
    logger.error("[!] Error: 'ai-edge-torch' is not installed.")
    logger.error("    Please run: pip install ai-edge-torch")
    exit(1)

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_definition import load_student_from_checkpoint, load_leaf_config


def convert_pth_to_tflite_aiedge(
    checkpoint_path: str,
    output_path: str,
    num_classes: int,
    quantize: str = "none"
):
    logger.info(f"\n{'='*60}")
    logger.info(f"  AgriKD: PyTorch -> TFLite (ai-edge-torch)")
    logger.info(f"{'='*60}")
    
    if not os.path.exists(checkpoint_path):
        raise FileNotFoundError(f"Checkpoint not found: {checkpoint_path}")
        
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    # 1. Load the model
    logger.info(f"[*] Loading PyTorch checkpoint: {checkpoint_path}")
    model = load_student_from_checkpoint(checkpoint_path, num_classes=num_classes)
    model.eval()
    
    # 2. Create sample input (1 image, 3 channels, 224x224)
    sample_input = (torch.randn(1, 3, 224, 224),)
    
    # 3. Handle Quantization Configuration
    quant_config = None
    if quantize == "dynamic":
        logger.info("[*] Applying Dynamic Range Quantization (INT8)...")
        try:
            import ai_edge_torch.quantize.quant_config as qcfg
            import ai_edge_torch.quantize.pt2e_quantizer as pt2e_q
            quant_config = qcfg.QuantConfig(
                pt2e_quantizer=pt2e_q.get_symmetric_quantization_config(is_dynamic=True)
            )
        except Exception as e:
            logger.warning(f"[!] Failed to setup quantizer: {e}")
            logger.warning("    Falling back to standard FP32 conversion.")
            quant_config = None
    
    # 4. Convert using ai-edge-torch
    logger.info("[*] Tracing and converting to TFLite Format...")
    start_time = time.time()
    
    try:
        if quant_config:
            edge_model = ai_edge_torch.convert(model, sample_input, quant_config=quant_config)
        else:
            edge_model = ai_edge_torch.convert(model, sample_input)
            
        logger.info(f"    Conversion took {time.time() - start_time:.2f} seconds.")
    except Exception as e:
        logger.error(f"\n[!] AI-Edge-Torch Conversion Failed:\n{e}")
        return

    # 5. Export to disk
    edge_model.export(output_path)
    logger.info(f"[OK] TFLite model successfully saved: {output_path}")
    
    # 6. Check sizes
    pth_size = os.path.getsize(checkpoint_path) / (1024 * 1024)
    tflite_size = os.path.getsize(output_path) / (1024 * 1024)
    compression = (1 - (tflite_size / pth_size)) * 100
    
    logger.info(f"    PTH Size:    {pth_size:.2f} MB")
    logger.info(f"    TFLite Size: {tflite_size:.2f} MB")
    logger.info(f"    Compression: {compression:.1f}% reduction")
    logger.info(f"{'='*60}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert PyTorch Model to TFLite via ai-edge-torch.")
    parser.add_argument("--config", type=str, default=None, help="Path to leaf config JSON (auto-fills other args)")
    parser.add_argument("--checkpoint", type=str, default=None, help="Input .pth checkpoint path")
    parser.add_argument("--output", type=str, default=None, help="Output .tflite path")
    parser.add_argument("--num-classes", type=int, default=None, help="Number of classes in the classifier")
    parser.add_argument("--quantize", choices=["none", "dynamic"], default="none", help="INT8 dynamic range quantization")

    args = parser.parse_args()

    if args.config:
        cfg = load_leaf_config(args.config)
        if args.checkpoint is None:
            args.checkpoint = cfg["_paths"]["checkpoint"]
        if args.num_classes is None:
            args.num_classes = cfg["num_classes"]
        if args.output is None:
            args.output = cfg["_paths"]["tflite"]

    if not args.checkpoint or args.num_classes is None or not args.output:
        parser.error("Either --config or all of --checkpoint, --num-classes, --output are required")

    convert_pth_to_tflite_aiedge(args.checkpoint, args.output, args.num_classes, args.quantize)
