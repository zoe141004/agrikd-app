import 'dart:async';
import 'dart:io' show File;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'package:app/core/utils/model_integrity.dart';
import 'package:app/data/database/dao/model_dao.dart';
import 'package:app/data/database/dao/preference_dao.dart';

class InferenceResult {
  final int classIndex;
  final double confidence;
  final List<double> allProbabilities;
  final double inferenceTimeMs;
  final String delegateUsed;

  const InferenceResult({
    required this.classIndex,
    required this.confidence,
    required this.allProbabilities,
    required this.inferenceTimeMs,
    required this.delegateUsed,
  });
}

class TfliteInferenceService {
  Interpreter? _interpreter;
  String? _currentLeafType;
  String? _currentVersion;
  String _delegateUsed = 'CPU';
  final ModelDao _modelDao = ModelDao();
  final PreferenceDao _preferenceDao = PreferenceDao();

  /// Async lock to serialize loadModel / loadModelFromFile / dispose.
  /// runInference() is synchronous so cannot be preempted in Dart's event loop.
  Completer<void>? _loadLock;

  Future<void> _acquireLoadLock() async {
    while (_loadLock != null) {
      await _loadLock!.future;
    }
    _loadLock = Completer<void>();
  }

  void _releaseLoadLock() {
    final lock = _loadLock;
    _loadLock = null;
    lock?.complete();
  }

  bool get isLoaded => _interpreter != null;
  String get currentLeafType => _currentLeafType ?? '';
  String get currentVersion => _currentVersion ?? '';
  String get delegateUsed => _delegateUsed;

  Future<void> loadModel(
    String assetPath, {
    String? leafType,
    String? version,
  }) async {
    await _acquireLoadLock();
    try {
      // Skip if same model+version already loaded
      if (_currentLeafType == leafType &&
          _currentVersion == version &&
          _interpreter != null)
        return;

      _disposeInterpreter();

      // Verify model integrity before loading
      if (leafType != null) {
        final modelRecord = await _modelDao.getSelected(leafType);
        if (modelRecord != null) {
          final expectedChecksum = modelRecord['sha256_checksum'] as String?;
          if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
            final isValid = await ModelIntegrity.verify(
              assetPath,
              expectedChecksum,
            );
            if (!isValid) {
              throw StateError(
                'Model integrity check failed for $leafType. '
                'The model file may be corrupted.',
              );
            }
          }
        }
      }

      // Try delegates with fallback: GPU -> XNNPack -> CPU
      _interpreter = await _loadWithDelegateFallback(assetPath);
      _currentLeafType = leafType;
      _currentVersion = version;
    } finally {
      _releaseLoadLock();
    }
  }

  /// Load an OTA model from the filesystem (not bundled asset).
  /// Verifies SHA-256 checksum from DB before loading to detect corruption.
  /// Returns false if loading or integrity check fails (caller should handle rollback).
  Future<bool> loadModelFromFile(
    String filePath, {
    String? leafType,
    String? version,
  }) async {
    await _acquireLoadLock();
    try {
      _disposeInterpreter();

      // Verify SHA-256 integrity before loading OTA model
      if (leafType != null) {
        final modelRecord = await _modelDao.getSelected(leafType);
        if (modelRecord != null) {
          final expectedChecksum = modelRecord['sha256_checksum'] as String?;
          if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
            final isValid = await ModelIntegrity.verifyFile(
              filePath,
              expectedChecksum,
            );
            if (!isValid) {
              return false;
            }
          }
        }
      }

      _interpreter = await _loadFromFileWithDelegateFallback(filePath);
      _currentLeafType = leafType;
      _currentVersion = version;
      return true;
    } catch (e) {
      debugPrint('[TFLite] Failed to load model for $leafType: $e');
      _interpreter = null;
      _currentLeafType = null;
      _currentVersion = null;
      return false;
    } finally {
      _releaseLoadLock();
    }
  }

  Future<Interpreter> _loadWithDelegateFallback(String assetPath) async {
    // Check if a preferred delegate was saved from a previous session
    final preferred = await _preferenceDao.getValue('preferred_delegate');

    // Try preferred delegate first, then fall through to others (skip duplicate)
    if (preferred == 'GPU') {
      try {
        return await _tryGpu(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU delegate failed: $e');
      }
      try {
        return await _tryXnnpack(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack delegate failed: $e');
      }
    } else if (preferred == 'XNNPack') {
      try {
        return await _tryXnnpack(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack delegate failed: $e');
      }
      try {
        return await _tryGpu(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU delegate failed: $e');
      }
    } else {
      // No preference or CPU: try GPU -> XNNPack
      try {
        return await _tryGpu(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU delegate failed: $e');
      }
      try {
        return await _tryXnnpack(assetPath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack delegate failed: $e');
      }
    }

    // Fallback to CPU
    final interpreter = await Interpreter.fromAsset(assetPath);
    _delegateUsed = 'CPU';
    if (preferred != 'CPU') {
      await _preferenceDao.setValue('preferred_delegate', 'CPU');
    }
    return interpreter;
  }

  Future<Interpreter> _tryGpu(
    String assetPath,
    String? currentPreferred,
  ) async {
    GpuDelegateV2? gpuDelegate;
    try {
      gpuDelegate = GpuDelegateV2();
      final options = InterpreterOptions()..addDelegate(gpuDelegate);
      final interpreter = await Interpreter.fromAsset(
        assetPath,
        options: options,
      );
      _delegateUsed = 'GPU';
      if (currentPreferred != 'GPU') {
        await _preferenceDao.setValue('preferred_delegate', 'GPU');
      }
      return interpreter;
    } catch (e) {
      gpuDelegate?.delete();
      rethrow;
    }
  }

  Future<Interpreter> _tryXnnpack(
    String assetPath,
    String? currentPreferred,
  ) async {
    XNNPackDelegate? xnnpackDelegate;
    try {
      xnnpackDelegate = XNNPackDelegate();
      final options = InterpreterOptions()..addDelegate(xnnpackDelegate);
      final interpreter = await Interpreter.fromAsset(
        assetPath,
        options: options,
      );
      _delegateUsed = 'XNNPack';
      if (currentPreferred != 'XNNPack') {
        await _preferenceDao.setValue('preferred_delegate', 'XNNPack');
      }
      return interpreter;
    } catch (e) {
      xnnpackDelegate?.delete();
      rethrow;
    }
  }

  // ── File-based loading (for OTA models) ──────────────────────────────────

  Future<Interpreter> _loadFromFileWithDelegateFallback(String filePath) async {
    final preferred = await _preferenceDao.getValue('preferred_delegate');

    if (preferred == 'GPU') {
      try {
        return await _tryGpuFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU file delegate failed: $e');
      }
      try {
        return await _tryXnnpackFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack file delegate failed: $e');
      }
    } else if (preferred == 'XNNPack') {
      try {
        return await _tryXnnpackFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack file delegate failed: $e');
      }
      try {
        return await _tryGpuFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU file delegate failed: $e');
      }
    } else {
      try {
        return await _tryGpuFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] GPU file delegate failed: $e');
      }
      try {
        return await _tryXnnpackFile(filePath, preferred);
      } catch (e) {
        debugPrint('[TFLite] XNNPack file delegate failed: $e');
      }
    }

    // Fallback to CPU
    final interpreter = Interpreter.fromFile(File(filePath));
    _delegateUsed = 'CPU';
    if (preferred != 'CPU') {
      await _preferenceDao.setValue('preferred_delegate', 'CPU');
    }
    return interpreter;
  }

  Future<Interpreter> _tryGpuFile(
    String filePath,
    String? currentPreferred,
  ) async {
    GpuDelegateV2? gpuDelegate;
    try {
      gpuDelegate = GpuDelegateV2();
      final options = InterpreterOptions()..addDelegate(gpuDelegate);
      final interpreter = Interpreter.fromFile(
        File(filePath),
        options: options,
      );
      _delegateUsed = 'GPU';
      if (currentPreferred != 'GPU') {
        await _preferenceDao.setValue('preferred_delegate', 'GPU');
      }
      return interpreter;
    } catch (e) {
      gpuDelegate?.delete();
      rethrow;
    }
  }

  Future<Interpreter> _tryXnnpackFile(
    String filePath,
    String? currentPreferred,
  ) async {
    XNNPackDelegate? xnnpackDelegate;
    try {
      xnnpackDelegate = XNNPackDelegate();
      final options = InterpreterOptions()..addDelegate(xnnpackDelegate);
      final interpreter = Interpreter.fromFile(
        File(filePath),
        options: options,
      );
      _delegateUsed = 'XNNPack';
      if (currentPreferred != 'XNNPack') {
        await _preferenceDao.setValue('preferred_delegate', 'XNNPack');
      }
      return interpreter;
    } catch (e) {
      xnnpackDelegate?.delete();
      rethrow;
    }
  }

  InferenceResult runInference(Float32List input, int numClasses) {
    if (_interpreter == null) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    // Prepare output buffer [1, numClasses]
    final output = List.filled(numClasses, 0.0).reshape([1, numClasses]);

    // Run inference with timing
    final stopwatch = Stopwatch()..start();
    _interpreter!.run(input.reshape([1, 224, 224, 3]), output);
    stopwatch.stop();

    // Apply softmax (numerically stable)
    final logits = (output[0] as List).cast<double>();
    final probs = _softmax(logits);

    // Get prediction
    int classIndex = 0;
    double maxProb = probs[0];
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > maxProb) {
        maxProb = probs[i];
        classIndex = i;
      }
    }

    return InferenceResult(
      classIndex: classIndex,
      confidence: maxProb,
      allProbabilities: probs,
      inferenceTimeMs: stopwatch.elapsedMicroseconds / 1000.0,
      delegateUsed: _delegateUsed,
    );
  }

  List<double> _softmax(List<double> logits) {
    final maxLogit = logits.reduce(max);
    final exps = logits.map((l) => exp(l - maxLogit)).toList();
    final sumExp = exps.reduce((a, b) => a + b);
    return exps.map((e) => e / sumExp).toList();
  }

  /// Internal dispose — no lock (called from within locked sections).
  void _disposeInterpreter() {
    _interpreter?.close();
    _interpreter = null;
    _currentLeafType = null;
    _currentVersion = null;
  }

  /// Public dispose — acquires lock to prevent racing with load operations.
  Future<void> dispose() async {
    await _acquireLoadLock();
    try {
      _disposeInterpreter();
    } finally {
      _releaseLoadLock();
    }
  }
}
