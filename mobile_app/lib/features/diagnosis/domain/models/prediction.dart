import 'dart:convert';

class Prediction {
  final int? id;
  final String imagePath;
  final String leafType;
  final String modelVersion;
  final int predictedClassIndex;
  final String predictedClassName;
  final double confidence;
  final List<double>? allConfidences;
  final double? inferenceTimeMs;
  final String? notes;
  final DateTime createdAt;
  final bool isSynced;
  final DateTime? syncedAt;
  final String? serverId;

  const Prediction({
    this.id,
    required this.imagePath,
    required this.leafType,
    required this.modelVersion,
    required this.predictedClassIndex,
    required this.predictedClassName,
    required this.confidence,
    this.allConfidences,
    this.inferenceTimeMs,
    this.notes,
    required this.createdAt,
    this.isSynced = false,
    this.syncedAt,
    this.serverId,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'image_path': imagePath,
      'leaf_type': leafType,
      'model_version': modelVersion,
      'predicted_class_index': predictedClassIndex,
      'predicted_class_name': predictedClassName,
      'confidence': confidence,
      'all_confidences': allConfidences != null
          ? jsonEncode(allConfidences)
          : null,
      'inference_time_ms': inferenceTimeMs,
      'notes': notes,
      'created_at': createdAt.toUtc().toIso8601String(),
      'is_synced': isSynced ? 1 : 0,
      'synced_at': syncedAt?.toUtc().toIso8601String(),
      'server_id': serverId,
    };
  }

  factory Prediction.fromMap(Map<String, dynamic> map) {
    return Prediction(
      id: map['id'] as int?,
      imagePath: map['image_path'] as String,
      leafType: map['leaf_type'] as String,
      modelVersion: map['model_version'] as String,
      predictedClassIndex: map['predicted_class_index'] as int,
      predictedClassName: map['predicted_class_name'] as String,
      confidence: (map['confidence'] as num).toDouble(),
      allConfidences: map['all_confidences'] != null
          ? (jsonDecode(map['all_confidences'] as String) as List)
                .map((e) => (e as num).toDouble())
                .toList()
          : null,
      inferenceTimeMs: (map['inference_time_ms'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      isSynced: (map['is_synced'] as int? ?? 0) == 1,
      syncedAt: map['synced_at'] != null
          ? DateTime.parse(map['synced_at'] as String)
          : null,
      serverId: map['server_id'] as String?,
    );
  }
}
