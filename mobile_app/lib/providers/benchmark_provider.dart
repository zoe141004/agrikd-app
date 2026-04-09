import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/config/supabase_config.dart';
import 'package:app/core/constants/model_constants.dart';

/// Remote model benchmark metrics fetched from Supabase `model_benchmarks`.
class ModelBenchmarkInfo {
  final String leafType;
  final String version;
  final double? accuracy;
  final double? precisionMacro;
  final double? recallMacro;
  final double? f1Macro;
  final double? flopsM;
  final double? latencyMeanMs;
  final double? sizeMb;
  final double? paramsM;

  const ModelBenchmarkInfo({
    required this.leafType,
    required this.version,
    this.accuracy,
    this.precisionMacro,
    this.recallMacro,
    this.f1Macro,
    this.flopsM,
    this.latencyMeanMs,
    this.sizeMb,
    this.paramsM,
  });
}

class BenchmarkState {
  final Map<String, ModelBenchmarkInfo> benchmarks; // keyed by leafType
  final bool isLoading;

  const BenchmarkState({this.benchmarks = const {}, this.isLoading = false});
}

class BenchmarkNotifier extends StateNotifier<BenchmarkState> {
  BenchmarkNotifier() : super(const BenchmarkState()) {
    load();
  }

  Future<void> load() async {
    state = BenchmarkState(benchmarks: state.benchmarks, isLoading: true);

    try {
      if (!SupabaseConfig.isInitialized) {
        state = BenchmarkState(benchmarks: state.benchmarks);
        return;
      }

      final client = SupabaseConfig.client;
      final result = <String, ModelBenchmarkInfo>{};

      for (final leafType in ModelConstants.availableLeafTypes) {
        // Query for the latest active version's tflite_float16 benchmark
        final rows = await client
            .from('model_benchmarks')
            .select('*')
            .eq('leaf_type', leafType)
            .eq('format', 'tflite_float16')
            .order('version', ascending: false)
            .limit(1);

        if (rows.isNotEmpty) {
          final r = rows.first;
          result[leafType] = ModelBenchmarkInfo(
            leafType: leafType,
            version: r['version'] as String? ?? '',
            accuracy: _toDouble(r['accuracy']),
            precisionMacro: _toDouble(r['precision_macro']),
            recallMacro: _toDouble(r['recall_macro']),
            f1Macro: _toDouble(r['f1_macro']),
            flopsM: _toDouble(r['flops_m']),
            latencyMeanMs: _toDouble(r['latency_mean_ms']),
            sizeMb: _toDouble(r['size_mb']),
            paramsM: _toDouble(r['params_m']),
          );
        }
      }

      state = BenchmarkState(benchmarks: result);
    } catch (e) {
      debugPrint('[BenchmarkProvider] Failed to load benchmarks: $e');
      state = BenchmarkState(benchmarks: state.benchmarks);
    }
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

final benchmarkProvider =
    StateNotifierProvider<BenchmarkNotifier, BenchmarkState>((ref) {
      return BenchmarkNotifier();
    });
