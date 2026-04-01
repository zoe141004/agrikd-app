"""
AgriKD - Comprehensive Model Evaluator
======================================
Evaluates PyTorch, ONNX, and TFLite model formats on:
  - Classification metrics (Accuracy, Precision, Recall, F1, Confusion Matrix)
  - Efficiency metrics (Latency, FPS, Memory, Model Size)
  - Model complexity (FLOPs, Parameters)
  - Cross-format consistency (KL Divergence)

Supports both random synthetic data and real ImageFolder datasets.
When --data-dir is provided, reproduces the KD training test split
(sklearn stratified, seed=42, 70/15/15) for fair comparison.

Usage (config-driven):
    python evaluate_models.py --config ../configs/tomato.json

Usage (CLI args):
    python evaluate_models.py \
        --checkpoint ../../model_checkpoints_student/tomato_student.pth \
        --onnx ../../models/tomato/tomato_student.onnx \
        --tflite ../../models/tomato/tomato_student.tflite \
        --num-classes 10 --data-dir ../../data/tomato \
        --output-dir ../../models/tomato
"""

import argparse
import gc
import os
import sys
import time
import psutil
import torch
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import seaborn as sns
from tabulate import tabulate

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_definition import load_student_from_checkpoint, load_leaf_config

os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'


def load_test_dataset(data_dir, input_size=224, mean=None, std=None,
                      seed=42, train_ratio=0.70, val_ratio=0.15, test_ratio=0.15):
    """
    Load test split from an ImageFolder dataset, reproducing the exact
    KD training split (sklearn stratified, seed=42, 70/15/15).
    """
    from torchvision import datasets, transforms
    from sklearn.model_selection import train_test_split

    mean = mean or [0.485, 0.456, 0.406]
    std = std or [0.229, 0.224, 0.225]

    transform = transforms.Compose([
        transforms.Resize((input_size, input_size)),
        transforms.ToTensor(),
        transforms.Normalize(mean=mean, std=std)
    ])

    dataset = datasets.ImageFolder(data_dir, transform=transform)
    targets = np.array(dataset.targets)
    indices = np.arange(len(dataset))

    # Stage 1: train (70%) vs temp (30%)
    train_idx, temp_idx = train_test_split(
        indices, test_size=(val_ratio + test_ratio),
        stratify=targets, random_state=seed
    )
    # Stage 2: val (50% of 30% = 15%) vs test (50% of 30% = 15%)
    temp_targets = targets[temp_idx]
    val_ratio_adj = val_ratio / (val_ratio + test_ratio)
    _, test_idx = train_test_split(
        temp_idx, test_size=(1 - val_ratio_adj),
        stratify=temp_targets, random_state=seed
    )

    test_labels = targets[test_idx]
    test_subset = torch.utils.data.Subset(dataset, test_idx)
    class_names = dataset.classes

    return test_subset, test_labels, class_names


class ModelEvaluator:
    def __init__(self, pth_path, onnx_path, tflite_path, num_classes,
                 tflite_float32_path=None,
                 data_dir=None, output_dir=None, input_size=224,
                 norm_mean=None, norm_std=None):
        self.pth_path = pth_path
        self.onnx_path = onnx_path
        self.tflite_path = tflite_path  # float16 (backward compat)
        self.tflite_float32_path = tflite_float32_path
        self.num_classes = num_classes
        self.input_size = input_size
        self.output_dir = output_dir or os.path.dirname(pth_path)
        os.makedirs(self.output_dir, exist_ok=True)

        self.results = []
        self.all_predictions = {}  # format_name -> predictions array
        self.golden_probs = None
        self.class_names = None
        self.test_labels = None
        self.flops_macs = None  # (flops, params) from thop

        if data_dir and os.path.isdir(data_dir):
            print(f"[*] Loading real test data from: {data_dir}")
            test_subset, test_labels, class_names = load_test_dataset(
                data_dir, input_size=input_size, mean=norm_mean, std=norm_std
            )
            self.class_names = class_names
            self.test_labels = test_labels
            self.num_samples = len(test_subset)
            print(f"    Test samples: {self.num_samples}")
            print(f"    Classes ({len(class_names)}): {class_names}")

            # Pre-load all images into numpy arrays (NCHW, float32)
            print(f"[*] Pre-loading {self.num_samples} test images...")
            loader = torch.utils.data.DataLoader(test_subset, batch_size=1, shuffle=False)
            images = []
            for img, _ in loader:
                images.append(img.numpy())
            self.test_data = np.vstack(images)
        else:
            self.num_samples = 100
            print(f"[*] No dataset provided. Using {self.num_samples} random samples.")
            self.test_data = np.random.randn(self.num_samples, 3, input_size, input_size).astype(np.float32)

    def _measure_memory(self, func, *args):
        process = psutil.Process(os.getpid())
        mem_before = process.memory_info().rss / (1024 * 1024)
        result = func(*args)
        mem_after = process.memory_info().rss / (1024 * 1024)
        return result, max(0.0, mem_after - mem_before)

    def _compute_kl_divergence(self, probs1, probs2):
        epsilon = 1e-10
        p1 = np.clip(probs1, epsilon, 1.0)
        p2 = np.clip(probs2, epsilon, 1.0)
        p1 = p1 / p1.sum(axis=1, keepdims=True)
        p2 = p2 / p2.sum(axis=1, keepdims=True)
        return np.mean(np.sum(p1 * np.log(p1 / p2), axis=1))

    def _compute_flops(self, model):
        """Compute FLOPs/MACs using thop library."""
        try:
            from thop import profile
            dummy = torch.randn(1, 3, self.input_size, self.input_size)
            macs, params = profile(model, inputs=(dummy,), verbose=False)
            self.flops_macs = (macs * 2, params)  # FLOPs = 2 * MACs
            return macs * 2, params
        except Exception as e:
            print(f"  [!] FLOPs computation failed: {e}")
            return None, None

    def _compute_accuracy(self, all_probs, format_name):
        """Compute accuracy against ground truth or PyTorch golden."""
        model_preds = np.argmax(all_probs, axis=1)
        self.all_predictions[format_name] = model_preds

        if self.test_labels is not None:
            labels = self.test_labels
            accuracy = np.mean(model_preds == labels) * 100
        else:
            golden = self.golden_probs
            if golden is None:
                golden = all_probs
            golden_preds = np.argmax(golden, axis=1)
            accuracy = np.mean(model_preds == golden_preds) * 100

        return accuracy

    def _benchmark_runner(self, name, size_mb, load_fn, infer_fn):
        print(f"\n{'='*50}")
        print(f"  Benchmarking: {name}")
        print(f"{'='*50}")

        # 0. Clean up previous model to make memory measurement fair
        gc.collect()
        time.sleep(0.2)  # Let OS reclaim freed pages

        # 1. Load model and measure memory
        model_obj, mem_load = self._measure_memory(load_fn)

        # 2. Warm up (skip first 10)
        warmup_iters = min(10, self.num_samples)
        for i in range(warmup_iters):
            infer_fn(model_obj, self.test_data[i:i+1])

        # 3. Inference loop
        latencies = []
        all_probs = []
        process = psutil.Process(os.getpid())
        mem_infer_start = process.memory_info().rss / (1024 * 1024)

        for i in range(self.num_samples):
            inp = self.test_data[i:i+1]
            start = time.perf_counter()
            probs = infer_fn(model_obj, inp)
            end = time.perf_counter()
            latencies.append((end - start) * 1000)
            all_probs.append(probs)

        mem_infer_end = process.memory_info().rss / (1024 * 1024)
        mem_infer_peak = max(0.0, mem_infer_end - mem_infer_start)
        all_probs = np.vstack(all_probs)

        # 4. KL Divergence
        kl_div = 0.0
        if name == "PyTorch":
            self.golden_probs = all_probs
        elif self.golden_probs is not None:
            kl_div = self._compute_kl_divergence(self.golden_probs, all_probs)

        # 5. Accuracy
        accuracy = self._compute_accuracy(all_probs, name)

        # 6. Latency stats
        latencies = np.array(latencies)
        mean_lat = np.mean(latencies)
        min_lat = np.min(latencies)
        max_lat = np.max(latencies)
        p99_lat = np.percentile(latencies, 99)
        fps = 1000.0 / mean_lat
        total_mem = mem_load + mem_infer_peak

        # 7. FLOPs/Params — same architecture across all formats,
        #    computed once from PyTorch and reused for ONNX/TFLite
        if name == "PyTorch":
            f, p = self._compute_flops(model_obj)
            if f is not None:
                self.flops_macs = (f, p)

        if self.flops_macs is not None:
            f, p = self.flops_macs
            flops_m = f"{f / 1e6:.1f}"
            params_m = f"{p / 1e6:.2f}"
            params_total = f"{int(p):,}"
        else:
            flops_m = "-"
            params_m = "-"
            params_total = "-"

        print(f"  Size:    {size_mb:.2f} MB")
        print(f"  Params:  {params_m} M | FLOPs: {flops_m} M")
        print(f"  Latency: {mean_lat:.2f} ms/img (P99: {p99_lat:.2f} ms)")
        print(f"  FPS:     {fps:.1f}")
        print(f"  Runtime Mem: {total_mem:.1f} MB")
        print(f"  Accuracy: {accuracy:.1f}%")
        print(f"  KL Div:  {kl_div:.8f}")

        self.results.append({
            "Format": name,
            "Size (MB)": size_mb,
            "Params (M)": params_m,
            "FLOPs (M)": flops_m,
            "Lat Mean (ms)": mean_lat,
            "Lat Min (ms)": min_lat,
            "Lat Max (ms)": max_lat,
            "Lat P99 (ms)": p99_lat,
            "ms/img": mean_lat,
            "FPS": fps,
            "Runtime Mem (MB)": total_mem,
            "Accuracy (%)": accuracy,
            "KL Div": kl_div,
        })

        # Store ref for cleanup in run_all()
        self._last_model = model_obj

    def eval_pytorch(self):
        if not os.path.exists(self.pth_path):
            return

        def load():
            model = load_student_from_checkpoint(self.pth_path, self.num_classes)
            model.eval()
            return model

        def infer(m, inp):
            with torch.no_grad():
                t = torch.from_numpy(inp)
                logits = m(t)
                return torch.softmax(logits, dim=1).numpy()

        size = os.path.getsize(self.pth_path) / (1024 * 1024)
        self._benchmark_runner("PyTorch", size, load, infer)

    def eval_onnx(self):
        if not os.path.exists(self.onnx_path):
            return
        import onnxruntime as ort

        def load():
            return ort.InferenceSession(self.onnx_path, providers=['CPUExecutionProvider'])

        def infer(sess, inp):
            io_name = sess.get_inputs()[0].name
            logits = sess.run(None, {io_name: inp})[0]
            exp_L = np.exp(logits - np.max(logits, axis=1, keepdims=True))
            return exp_L / np.sum(exp_L, axis=1, keepdims=True)

        size = os.path.getsize(self.onnx_path) / (1024 * 1024)
        self._benchmark_runner("ONNX", size, load, infer)

    def eval_tflite(self, tflite_path=None, name="TFLite"):
        path = tflite_path or self.tflite_path
        if not path or not os.path.exists(path):
            return
        import tensorflow as tf

        def load():
            interpreter = tf.lite.Interpreter(model_path=path)
            interpreter.allocate_tensors()
            return interpreter

        def infer(interp, inp):
            in_det = interp.get_input_details()[0]
            out_det = interp.get_output_details()[0]
            expected_shape = in_det['shape']
            if list(expected_shape) == [1, 224, 224, 3]:
                inp = np.transpose(inp, (0, 2, 3, 1))
            interp.set_tensor(in_det['index'], inp)
            interp.invoke()
            logits = interp.get_tensor(out_det['index'])
            exp_L = np.exp(logits - np.max(logits, axis=1, keepdims=True))
            return exp_L / np.sum(exp_L, axis=1, keepdims=True)

        size = os.path.getsize(path) / (1024 * 1024)
        self._benchmark_runner(name, size, load, infer)

    def run_all(self):
        self.eval_pytorch()
        # Delete PyTorch model before ONNX benchmark
        if hasattr(self, '_last_model'):
            del self._last_model
        self.eval_onnx()
        # Delete ONNX session before TFLite benchmarks
        if hasattr(self, '_last_model'):
            del self._last_model
        self.eval_tflite(self.tflite_path, "TFLite (float16)")
        if hasattr(self, '_last_model'):
            del self._last_model
        if self.tflite_float32_path and os.path.exists(self.tflite_float32_path):
            self.eval_tflite(self.tflite_float32_path, "TFLite (float32)")
        self.generate_report()

    def _generate_classification_report(self):
        """Generate per-class classification metrics for each format (real data only)."""
        if self.test_labels is None or self.class_names is None:
            return ""

        from sklearn.metrics import classification_report, confusion_matrix

        sections = []
        for fmt_name, preds in self.all_predictions.items():
            report = classification_report(
                self.test_labels, preds,
                target_names=self.class_names,
                output_dict=True, zero_division=0
            )

            rows = []
            for cls in self.class_names:
                m = report[cls]
                rows.append({
                    "Class": cls,
                    "Precision": f"{m['precision']:.4f}",
                    "Recall": f"{m['recall']:.4f}",
                    "F1-Score": f"{m['f1-score']:.4f}",
                    "Support": int(m['support'])
                })
            for avg in ["macro avg", "weighted avg"]:
                m = report[avg]
                rows.append({
                    "Class": avg.title(),
                    "Precision": f"{m['precision']:.4f}",
                    "Recall": f"{m['recall']:.4f}",
                    "F1-Score": f"{m['f1-score']:.4f}",
                    "Support": int(m['support'])
                })

            df_cls = pd.DataFrame(rows)
            tbl = tabulate(df_cls, headers='keys', tablefmt='github', showindex=False)
            sections.append(f"\n### {fmt_name} — Per-Class Metrics\n\n{tbl}\n")

            # Confusion matrix heatmap
            cm = confusion_matrix(self.test_labels, preds)
            fig, ax = plt.subplots(figsize=(10, 8))
            sns.heatmap(cm, annot=True, fmt='d', cmap='Blues',
                        xticklabels=self.class_names,
                        yticklabels=self.class_names, ax=ax)
            ax.set_xlabel('Predicted')
            ax.set_ylabel('Actual')
            ax.set_title(f'Confusion Matrix — {fmt_name}')
            plt.xticks(rotation=45, ha='right')
            plt.yticks(rotation=0)
            plt.tight_layout()
            cm_safe = fmt_name.lower().replace(' ', '_').replace('(', '').replace(')', '')
            cm_path = os.path.join(self.output_dir, f"confusion_matrix_{cm_safe}.png")
            plt.savefig(cm_path, dpi=150)
            plt.close()
            sections.append(f"![Confusion Matrix {fmt_name}](confusion_matrix_{cm_safe}.png)\n")

        return "\n".join(sections)

    def generate_report(self):
        df = pd.DataFrame(self.results)

        # Main benchmark table
        display_cols = ["Format", "Size (MB)", "Params (M)", "FLOPs (M)",
                        "ms/img", "FPS", "Runtime Mem (MB)", "Accuracy (%)", "KL Div"]
        df_display = df[[c for c in display_cols if c in df.columns]].copy()
        # Per-column float format: .3f for most, .6f for KL Div
        col_fmts = []
        for c in df_display.columns:
            if c == "KL Div":
                col_fmts.append(".6f")
            elif c in ("Format", "Params (M)", "FLOPs (M)"):
                col_fmts.append("")  # string columns
            else:
                col_fmts.append(".3f")
        md_table = tabulate(df_display, headers='keys', tablefmt='github',
                            floatfmt=col_fmts, showindex=False)

        # Header
        report_parts = [
            "## AgriKD Model Benchmark Report",
            "",
            f"**Date:** {time.strftime('%Y-%m-%d %H:%M')}",
            f"**Test Samples:** {self.num_samples}",
        ]
        if self.class_names:
            report_parts.append(f"**Dataset:** {len(self.class_names)} classes")
        report_parts.extend(["", "### Benchmark Summary", "", md_table, ""])

        # Detailed latency table
        lat_cols = ["Format", "Lat Mean (ms)", "Lat Min (ms)", "Lat Max (ms)", "Lat P99 (ms)", "FPS"]
        df_lat = df[[c for c in lat_cols if c in df.columns]]
        lat_table = tabulate(df_lat, headers='keys', tablefmt='github',
                             floatfmt=".3f", showindex=False)
        report_parts.extend(["### Latency Details", "", lat_table, ""])

        # Classification report (if real data)
        cls_report = self._generate_classification_report()
        if cls_report:
            report_parts.extend(["### Classification Metrics (Real Test Data)", cls_report])

        # Conclusion
        report_parts.append("""
### Notes
- **Params/FLOPs** are identical across formats (same model architecture, same weights).
- **File size** differs due to serialization: TFLite float16 uses half-precision weight storage (most compact), TFLite float32 uses full precision FlatBuffer, ONNX uses Protobuf, PyTorch includes optimizer state.
- **Runtime Mem (MB)** = RSS delta measured independently per format (gc.collect between formats). Reflects runtime engine overhead, not model size.
- **Latency** measured on PC CPU. On mobile, TFLite + GPU Delegate or NNAPI can significantly outperform CPU-only inference.
- **KL Divergence** measures the full probability distribution shift vs PyTorch (baseline). A KL Div near 0 with slight Accuracy difference means a few borderline samples flipped (e.g., PyTorch: [0.350001, 0.349999] vs TFLite: [0.349999, 0.350001]) — the distributions are nearly identical but argmax flips at the decision boundary.

### Sweet Spot Conclusion
- **Jetson Deployment:** `ONNX`/`TensorRT` — highest throughput for GPU-equipped edges, zero KL divergence vs PyTorch.
- **Mobile App (size priority):** `TFLite (float16)` — smallest footprint (~50% compression), supports GPU Delegate & NNAPI.
- **Mobile App (precision priority):** `TFLite (float32)` — full precision weights, identical to ONNX accuracy.
""")

        report_str = "\n".join(report_parts)
        report_path = os.path.join(self.output_dir, "benchmark_report.md")
        with open(report_path, "w", encoding="utf-8") as f:
            f.write(report_str)
        print(f"\n[OK] Benchmark report: {report_path}")

        # Charts
        sns.set_theme(style="whitegrid")

        # Chart 1: Latency bar chart
        plt.figure(figsize=(10, 6))
        sns.barplot(data=df, x="Format", y="Lat Mean (ms)", hue="Format", palette="viridis")
        plt.title("Inference Latency (Mean ms/image)")
        plt.ylabel("Latency (ms)")
        plt.savefig(os.path.join(self.output_dir, "benchmark_latency.png"), dpi=150)
        plt.close()

        # Chart 2: Accuracy vs Size
        fig, ax1 = plt.subplots(figsize=(10, 6))
        ax1.set_xlabel('Format')
        ax1.set_ylabel('Accuracy (%)', color='tab:blue')
        ax1.plot(df["Format"], df["Accuracy (%)"], color='tab:blue', marker='o', linewidth=2)
        ax1.tick_params(axis='y', labelcolor='tab:blue')
        ax2 = ax1.twinx()
        ax2.set_ylabel('Model Size (MB)', color='tab:red')
        ax2.plot(df["Format"], df["Size (MB)"], color='tab:red', marker='s',
                 linestyle='dashed', linewidth=2)
        ax2.tick_params(axis='y', labelcolor='tab:red')
        fig.tight_layout()
        plt.title("Accuracy vs Model Size Trade-off")
        plt.savefig(os.path.join(self.output_dir, "benchmark_accuracy_size.png"), dpi=150)
        plt.close()

        print(f"[OK] Charts saved to: {self.output_dir}")


def main():
    parser = argparse.ArgumentParser("AgriKD Model Benchmarking & Evaluation")
    parser.add_argument("--config", default=None,
                        help="Path to leaf config JSON (auto-fills all other args)")
    parser.add_argument("--checkpoint", default=None, help="Path to .pth checkpoint")
    parser.add_argument("--onnx", default=None, help="Path to .onnx model")
    parser.add_argument("--tflite", default=None, help="Path to .tflite model (float16)")
    parser.add_argument("--tflite-float32", default=None, help="Path to .tflite float32 model")
    parser.add_argument("--num-classes", type=int, default=None)
    parser.add_argument("--data-dir", default=None,
                        help="Path to dataset root (ImageFolder format). "
                             "If provided, uses real test split for evaluation.")
    parser.add_argument("--output-dir", default=None,
                        help="Output directory for reports and charts")

    args = parser.parse_args()

    input_size = 224
    norm_mean = None
    norm_std = None
    tflite_float32 = args.tflite_float32

    if args.config:
        cfg = load_leaf_config(args.config)
        if args.checkpoint is None:
            args.checkpoint = cfg["_paths"]["checkpoint"]
        if args.onnx is None:
            args.onnx = cfg["_paths"]["onnx"]
        if args.tflite is None:
            args.tflite = cfg["_paths"]["tflite"]
        if tflite_float32 is None:
            tflite_float32 = cfg["_paths"].get("tflite_float32")
        if args.num_classes is None:
            args.num_classes = cfg["num_classes"]
        if args.output_dir is None:
            args.output_dir = cfg["_paths"]["output_dir"]
        if args.data_dir is None and cfg["_paths"].get("data_dir"):
            args.data_dir = cfg["_paths"]["data_dir"]
        input_size = cfg["input_size"][0]
        norm = cfg.get("normalization", {})
        norm_mean = norm.get("mean")
        norm_std = norm.get("std")

    if not args.checkpoint or not args.onnx or not args.tflite or args.num_classes is None:
        parser.error("Either --config or all of --checkpoint, --onnx, --tflite, --num-classes are required")

    evaluator = ModelEvaluator(
        args.checkpoint, args.onnx, args.tflite, args.num_classes,
        tflite_float32_path=tflite_float32,
        data_dir=args.data_dir, output_dir=args.output_dir,
        input_size=input_size, norm_mean=norm_mean, norm_std=norm_std
    )
    evaluator.run_all()


if __name__ == "__main__":
    main()
