"""
AgriKD - Student Model Definition
==================================
Defines the MobileNetV2-based student model architecture used in
Knowledge Distillation for leaf disease classification.

Architecture (from KD checkpoint analysis):
    - Backbone: Truncated MobileNetV2 features[0:12] (output: 96 channels)
    - Global Average Pooling -> [batch, 96]
    - Custom Classifier Head:
        classifier.0: Linear(96, 512) + ReLU + Dropout
        classifier.3: Linear(512, 256) + ReLU + Dropout
        classifier.6: Linear(256, num_classes)

Checkpoint key structure:
    backbone.backbone.features.{0..11}.*   (MobileNetV2 conv layers)
    classifier.{0,3,6}.*                    (Custom FC layers)

Usage:
    model = create_student_model(num_classes=10)
    model = load_student_from_checkpoint("path/to/checkpoint.pth", num_classes=10)
"""

import logging
import os

import torch
import torch.nn as nn
from torchvision import models

logger = logging.getLogger(__name__)

# Number of MobileNetV2 feature blocks used in the student backbone
# Full MobileNetV2 has features[0:19] (1280 output); student uses [0:12] (96 output)
_BACKBONE_FEATURE_COUNT = 12
_BACKBONE_OUTPUT_DIM = 96

# Classifier hidden dimensions (shared across all leaf models)
_CLASSIFIER_HIDDEN_DIMS = [512, 256]
_DROPOUT_RATE = 0.3


class StudentBackbone(nn.Module):
    """
    Truncated MobileNetV2 backbone.
    
    Uses only the first 12 feature blocks of MobileNetV2,
    outputting 96-dimensional features instead of the full 1280.
    This matches the KD training setup where the student backbone
    is intentionally smaller for edge deployment.
    """

    def __init__(self):
        super().__init__()
        full_mobilenet = models.mobilenet_v2(weights=None)
        # Take only the first 12 feature blocks
        self.backbone = nn.Sequential(
            *list(full_mobilenet.features.children())[:_BACKBONE_FEATURE_COUNT]
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.backbone(x)


class CustomClassifier(nn.Module):
    """
    Custom fully connected classifier head.
    
    Matches the KD training CustomClassifier:
        For each hidden_dim in config: Linear -> ReLU -> Dropout
        Final: Linear(last_hidden, num_classes)
    
    With default config [512, 256]:
        classifier.0: Linear(96, 512)
        classifier.1: ReLU
        classifier.2: Dropout
        classifier.3: Linear(512, 256)
        classifier.4: ReLU
        classifier.5: Dropout
        classifier.6: Linear(256, num_classes)
    """

    def __init__(
        self,
        in_features: int,
        num_classes: int,
        hidden_dims: list = None,
        dropout_rate: float = _DROPOUT_RATE,
    ):
        super().__init__()
        
        if hidden_dims is None:
            hidden_dims = _CLASSIFIER_HIDDEN_DIMS

        layers = []
        prev_dim = in_features

        for hidden_dim in hidden_dims:
            layers.extend([
                nn.Linear(prev_dim, hidden_dim),
                nn.ReLU(inplace=False),
                nn.Dropout(dropout_rate),
            ])
            prev_dim = hidden_dim

        # Final classification layer
        layers.append(nn.Linear(prev_dim, num_classes))

        self.classifier = nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.classifier(x)


class LeafDiseaseStudentModel(nn.Module):
    """
    Complete student model for leaf disease classification.
    
    Combines the truncated MobileNetV2 backbone with the custom
    classifier head. Designed to match KD checkpoint structure exactly.
    
    Checkpoint key mapping:
        self.backbone.backbone.features.*  -> backbone.backbone.features.*
        self.classifier.classifier.*       -> classifier.classifier.*
        
    Note: We remap keys during loading to strip the extra nesting,
    matching the flat checkpoint structure.
    
    Args:
        num_classes: Number of disease classes for this leaf type.
        classifier_hidden_dims: Hidden layer sizes (default: [512, 256]).
        dropout_rate: Dropout probability in classifier head.
    """

    def __init__(
        self,
        num_classes: int,
        classifier_hidden_dims: list = None,
        dropout_rate: float = _DROPOUT_RATE,
    ):
        super().__init__()
        self.backbone = StudentBackbone()
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.classifier = CustomClassifier(
            in_features=_BACKBONE_OUTPUT_DIM,
            num_classes=num_classes,
            hidden_dims=classifier_hidden_dims,
            dropout_rate=dropout_rate,
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        Forward pass.
        
        Args:
            x: Input tensor [batch, 3, 224, 224]
        Returns:
            Logits tensor [batch, num_classes]
        """
        features = self.backbone(x)              # [B, 96, H, W]
        features = self.pool(features)           # [B, 96, 1, 1]
        features = torch.flatten(features, 1)    # [B, 96]
        logits = self.classifier(features)       # [B, num_classes]
        return logits


def create_student_model(
    num_classes: int,
    classifier_hidden_dims: list = None,
) -> LeafDiseaseStudentModel:
    """
    Factory: create a new (untrained) student model.
    """
    return LeafDiseaseStudentModel(
        num_classes=num_classes,
        classifier_hidden_dims=classifier_hidden_dims,
    )


def _remap_checkpoint_keys(state_dict: dict) -> dict:
    """
    Remap checkpoint keys to match our model structure.
    
    Checkpoint keys:           Our model keys:
    backbone.backbone.features.* -> backbone.backbone.features.*  (same)
    classifier.0.*              -> classifier.classifier.0.*      (need prefix)
    
    The checkpoint stores classifier weights directly as classifier.{idx}.*,
    but our CustomClassifier wraps them in self.classifier (Sequential),
    so our model expects classifier.classifier.{idx}.*
    """
    new_state_dict = {}
    for key, value in state_dict.items():
        if key.startswith("backbone.backbone.features."):
            # Map 'backbone.backbone.features.X' to 'backbone.backbone.X'
            new_key = "backbone.backbone." + key[len("backbone.backbone.features."):]
        elif key.startswith("classifier.") and not key.startswith("classifier.classifier."):
            # Add the extra .classifier nesting
            new_key = "classifier.classifier." + key[len("classifier."):]
        else:
            new_key = key
        new_state_dict[new_key] = value
    return new_state_dict


def _infer_classifier_dims(state_dict: dict) -> list:
    """Infer classifier hidden dimensions from checkpoint weight shapes.

    Scans for classifier.N.weight keys (after remapping) and extracts
    the output dimensions of each hidden Linear layer (excluding final).
    """
    classifier_weights = {}
    for key, value in state_dict.items():
        # Match classifier.classifier.N.weight or classifier.N.weight
        for prefix in ("classifier.classifier.", "classifier."):
            if key.startswith(prefix) and key.endswith(".weight"):
                idx_str = key[len(prefix):].split(".")[0]
                if idx_str.isdigit():
                    classifier_weights[int(idx_str)] = value.shape
                break

    if not classifier_weights:
        return None

    # Sort by layer index; hidden layers have out_features != num_classes
    sorted_indices = sorted(classifier_weights.keys())
    # All layers except the last are hidden layers
    hidden_dims = [classifier_weights[i][0] for i in sorted_indices[:-1]]
    return hidden_dims if hidden_dims else None


def load_student_from_checkpoint(
    checkpoint_path: str,
    num_classes: int,
    classifier_hidden_dims: list = None,
    device: str = "cpu",
) -> LeafDiseaseStudentModel:
    """
    Load a trained student model from a KD checkpoint file.
    
    Handles key remapping between checkpoint format and model structure.
    Auto-detects classifier_hidden_dims from checkpoint weights if not provided.
    
    Args:
        checkpoint_path: Path to the .pth checkpoint file.
        num_classes: Number of classes for this leaf type.
        classifier_hidden_dims: Hidden dims (auto-detected from checkpoint if None).
        device: Target device.
        
    Returns:
        LeafDiseaseStudentModel with loaded weights, set to eval mode.
    """
    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    
    if "student_state_dict" not in checkpoint:
        raise KeyError(
            f"Checkpoint at '{checkpoint_path}' does not contain "
            f"'student_state_dict'. Available keys: {list(checkpoint.keys())}"
        )
    
    # Remap keys to match our model structure
    raw_state_dict = checkpoint["student_state_dict"]
    remapped_state_dict = _remap_checkpoint_keys(raw_state_dict)
    
    # Auto-detect classifier hidden dims from checkpoint if not specified
    if classifier_hidden_dims is None:
        detected = _infer_classifier_dims(remapped_state_dict)
        if detected:
            logger.info(f"     Auto-detected classifier_hidden_dims: {detected}")
            classifier_hidden_dims = detected
    
    # Create model and load weights
    model = create_student_model(
        num_classes=num_classes,
        classifier_hidden_dims=classifier_hidden_dims,
    )
    
    # Use strict=False to ignore 'num_batches_tracked' buffer mismatches
    incompatible_keys = model.load_state_dict(remapped_state_dict, strict=False)
    
    # Check if any actual trained weights are missing
    missing_weights = [k for k in incompatible_keys.missing_keys if 'num_batches_tracked' not in k]
    if missing_weights:
        logger.warning(f"[!] Warning: missing keys from checkpoint: {missing_weights[:5]}...")

    logger.info(f"     Classes: {num_classes}, Device: {device}")
    logger.info(f"     Backbone: MobileNetV2 features[0:{_BACKBONE_FEATURE_COUNT}] ({_BACKBONE_OUTPUT_DIM}d)")
    logger.info(f"     Classifier: {_BACKBONE_OUTPUT_DIM} -> {classifier_hidden_dims or _CLASSIFIER_HIDDEN_DIMS} -> {num_classes}")
    
    if "epoch" in checkpoint:
        logger.info(f"     Trained for: {checkpoint['epoch']} epochs")
    if "val_loss" in checkpoint:
        logger.info(f"     Val loss: {checkpoint['val_loss']:.4f}")
    
    model.eval()
    return model


def load_leaf_config(config_path):
    """Load leaf model config JSON and resolve paths relative to project root.

    Returns dict with keys: leaf_type, num_classes, input_size,
    normalization, checkpoint_filename, data_dir, etc.
    Also adds resolved absolute paths under '_paths' key.
    """
    import json

    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)

    # Validate critical config fields
    num_classes = config.get("num_classes")
    if num_classes is None or not isinstance(num_classes, int) or num_classes < 2 or num_classes > 1000:
        raise ValueError(f"num_classes must be int in [2, 1000], got: {num_classes}")
    input_size = config.get("input_size")
    # Accept both int (square) and [H, W] list/tuple; default to 224x224 if missing
    if input_size is None:
        import logging as _logging
        _logging.getLogger(__name__).warning(
            "input_size not found in config '%s', defaulting to [224, 224]", config_path
        )
        input_size = [224, 224]
        config["input_size"] = input_size
    if isinstance(input_size, (list, tuple)):
        if len(input_size) != 2 or not all(isinstance(v, int) and 32 <= v <= 1024 for v in input_size):
            raise ValueError(f"input_size list must be [H, W] with ints in [32, 1024], got: {input_size}")
    elif isinstance(input_size, int):
        if input_size < 32 or input_size > 1024:
            raise ValueError(f"input_size must be in [32, 1024], got: {input_size}")
        config["input_size"] = [input_size, input_size]
    else:
        raise ValueError(f"input_size must be int or [H, W] list, got: {input_size}")
    if not config.get("leaf_type") or not isinstance(config["leaf_type"], str):
        raise ValueError(f"leaf_type must be a non-empty string, got: {config.get('leaf_type')}")

    # Project root: two levels up from this script (scripts/ -> mlops_pipeline/ -> root)
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

    leaf = config["leaf_type"]
    ckpt_name = config.get("checkpoint_filename", f"{leaf}_student.pth")

    config["_paths"] = {
        "project_root": project_root,
        "checkpoint": os.path.join(project_root, "model_checkpoints_student", ckpt_name),
        "onnx": os.path.join(project_root, "models", leaf, f"{leaf}_student.onnx"),
        "tflite": os.path.join(project_root, "models", leaf, f"{leaf}_student.tflite"),
        "tflite_float16": os.path.join(project_root, "models", leaf, f"{leaf}_student_float16.tflite"),
        "tflite_float32": os.path.join(project_root, "models", leaf, f"{leaf}_student_float32.tflite"),
        "output_dir": os.path.join(project_root, "models", leaf),
    }

    if config.get("data_dir"):
        config["_paths"]["data_dir"] = os.path.join(project_root, config["data_dir"])

    return config


if __name__ == "__main__":
    # Sanity check: verify model architecture
    for num_cls, name in [(10, "Tomato"), (5, "Burmese Grape Leaf")]:
        model = create_student_model(num_classes=num_cls)
        dummy_input = torch.randn(1, 3, 224, 224)
        output = model(dummy_input)
        logger.info(f"{name}: input={list(dummy_input.shape)} -> output={list(output.shape)}")
        assert output.shape == (1, num_cls), f"Expected (1, {num_cls}), got {output.shape}"
    
    # Verify key names match checkpoint format after remapping
    model = create_student_model(num_classes=10)
    model_keys = set(model.state_dict().keys())
    logger.info(f"\nModel has {len(model_keys)} parameters")
    logger.debug(f"Sample keys: {sorted(list(model_keys))[:3]}")
    logger.debug(f"Classifier keys: {sorted([k for k in model_keys if 'classifier' in k])}")
    
    logger.info("\n[OK] All model architecture checks passed!")
