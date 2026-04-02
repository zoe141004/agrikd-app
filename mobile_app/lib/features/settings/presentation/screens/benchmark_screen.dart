import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:app/core/constants/app_constants.dart';
import 'package:app/core/constants/model_constants.dart';
import 'package:app/core/l10n/app_strings.dart';
import 'package:app/features/diagnosis/data/tflite_inference_service.dart';

const int _warmUpRuns = 10;
const int _benchmarkRuns = 50;

class _ModelBenchmark {
  final String leafType;
  final String delegate;
  final String modelSize;
  final double meanMs;
  final double minMs;
  final double maxMs;
  final double p99Ms;
  final double fps;

  const _ModelBenchmark({
    required this.leafType,
    required this.delegate,
    required this.modelSize,
    required this.meanMs,
    required this.minMs,
    required this.maxMs,
    required this.p99Ms,
    required this.fps,
  });
}

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  bool _isRunning = false;
  bool _isDone = false;
  String _status = '';
  final List<_ModelBenchmark> _results = [];

  static const _modelSizes = {
    'tomato': '1.00 MB',
    'burmese_grape_leaf': '0.98 MB',
  };

  Future<void> _runBenchmark() async {
    setState(() {
      _isRunning = true;
      _isDone = false;
      _results.clear();
    });

    final service = TfliteInferenceService();
    final dummyInput = _createDummyInput();

    try {
      for (final leafType in ModelConstants.availableLeafTypes) {
        final modelInfo = ModelConstants.getModel(leafType);

        // Load model
        setState(() => _status = '${modelInfo.englishName}: loading...');
        await service.loadModel(modelInfo.assetPath, leafType: leafType);

        // Warm-up
        setState(
          () => _status = '${modelInfo.englishName}: ${S.get('warm_up')}...',
        );
        for (int i = 0; i < _warmUpRuns; i++) {
          service.runInference(dummyInput, modelInfo.numClasses);
          if (i % 5 == 0) await Future.delayed(Duration.zero); // yield to UI
        }

        // Timed runs
        setState(
          () => _status =
              '${modelInfo.englishName}: ${S.fmt('iterations', [_benchmarkRuns])}...',
        );
        final latencies = <double>[];
        for (int i = 0; i < _benchmarkRuns; i++) {
          final result = service.runInference(dummyInput, modelInfo.numClasses);
          latencies.add(result.inferenceTimeMs);
          if (i % 10 == 0) await Future.delayed(Duration.zero); // yield to UI
        }

        latencies.sort();
        final mean = latencies.reduce((a, b) => a + b) / latencies.length;
        final minMs = latencies.first;
        final maxMs = latencies.last;
        final p99Index = ((latencies.length * 0.99).ceil() - 1).clamp(
          0,
          latencies.length - 1,
        );
        final p99 = latencies[p99Index];

        _results.add(
          _ModelBenchmark(
            leafType: leafType,
            delegate: service.delegateUsed,
            modelSize: _modelSizes[leafType] ?? '~1 MB',
            meanMs: mean,
            minMs: minMs,
            maxMs: maxMs,
            p99Ms: p99,
            fps: 1000.0 / mean,
          ),
        );

        // Dispose between models for clean measurement
        service.dispose();
      }

      setState(() {
        _isRunning = false;
        _isDone = true;
        _status = S.get('benchmark_done');
      });
    } catch (e) {
      setState(() {
        _isRunning = false;
        _status = S.get('err_benchmark_failed');
      });
    } finally {
      service.dispose();
    }
  }

  /// Creates a solid gray 224x224 image in preprocessed Float32 format.
  Float32List _createDummyInput() {
    const size = AppConstants.imageSize;
    const mean = AppConstants.imagenetMean;
    const std = AppConstants.imagenetStd;
    final input = Float32List(1 * size * size * 3);

    for (int i = 0; i < size * size; i++) {
      final idx = i * 3;
      input[idx + 0] = (0.5 - mean[0]) / std[0];
      input[idx + 1] = (0.5 - mean[1]) / std[1];
      input[idx + 2] = (0.5 - mean[2]) / std[2];
    }
    return input;
  }

  String _buildMarkdownReport() {
    final buf = StringBuffer();
    buf.writeln('# TFLite On-Device Benchmark');
    buf.writeln();
    buf.writeln(
      '| Metric | ${_results.map((r) => ModelConstants.getModel(r.leafType).englishName).join(' | ')} |',
    );
    buf.writeln('|--------|${_results.map((_) => '--------').join('|')}|');
    buf.writeln(
      '| Delegate | ${_results.map((r) => r.delegate).join(' | ')} |',
    );
    buf.writeln(
      '| Model size | ${_results.map((r) => r.modelSize).join(' | ')} |',
    );
    buf.writeln(
      '| Warm-up | ${_results.map((_) => '$_warmUpRuns runs').join(' | ')} |',
    );
    buf.writeln(
      '| Iterations | ${_results.map((_) => '$_benchmarkRuns').join(' | ')} |',
    );
    buf.writeln(
      '| Mean | ${_results.map((r) => '${r.meanMs.toStringAsFixed(2)} ms').join(' | ')} |',
    );
    buf.writeln(
      '| Min | ${_results.map((r) => '${r.minMs.toStringAsFixed(2)} ms').join(' | ')} |',
    );
    buf.writeln(
      '| Max | ${_results.map((r) => '${r.maxMs.toStringAsFixed(2)} ms').join(' | ')} |',
    );
    buf.writeln(
      '| P99 | ${_results.map((r) => '${r.p99Ms.toStringAsFixed(2)} ms').join(' | ')} |',
    );
    buf.writeln(
      '| FPS | ${_results.map((r) => r.fps.toStringAsFixed(1)).join(' | ')} |',
    );
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(S.get('benchmark'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Run button
          if (!_isRunning && !_isDone)
            Center(
              child: Column(
                children: [
                  Icon(Icons.speed, size: 64, color: colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    S.get('benchmark_sub'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _runBenchmark,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(S.get('run_benchmark')),
                  ),
                ],
              ),
            ),

          // Progress
          if (_isRunning) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              _status,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],

          // Results
          if (_isDone) ...[
            ..._results.map((r) {
              final modelInfo = ModelConstants.getModel(r.leafType);
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        modelInfo.localizedName(S.locale),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      _BenchRow(S.get('delegate'), r.delegate),
                      _BenchRow(S.get('model_size'), r.modelSize),
                      _BenchRow(S.get('warm_up'), '$_warmUpRuns runs'),
                      _BenchRow(S.get('iterations'), '$_benchmarkRuns'),
                      const Divider(height: 16),
                      _BenchRow(
                        S.get('lat_mean'),
                        '${r.meanMs.toStringAsFixed(2)} ms',
                      ),
                      _BenchRow(
                        S.get('lat_min'),
                        '${r.minMs.toStringAsFixed(2)} ms',
                      ),
                      _BenchRow(
                        S.get('lat_max'),
                        '${r.maxMs.toStringAsFixed(2)} ms',
                      ),
                      _BenchRow(
                        S.get('lat_p99'),
                        '${r.p99Ms.toStringAsFixed(2)} ms',
                      ),
                      _BenchRow(S.get('fps'), r.fps.toStringAsFixed(1)),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _runBenchmark,
                    icon: const Icon(Icons.refresh),
                    label: Text(S.get('run_benchmark')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _buildMarkdownReport()),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(S.get('report_copied'))),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(S.get('copy_report')),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BenchRow extends StatelessWidget {
  final String label;
  final String value;

  const _BenchRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
