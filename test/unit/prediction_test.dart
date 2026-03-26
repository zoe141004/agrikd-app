import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/diagnosis/domain/models/prediction.dart';

void main() {
  group('Prediction', () {
    final now = DateTime.utc(2026, 3, 23, 12, 0, 0);

    final sampleMap = <String, dynamic>{
      'id': 1,
      'image_path': '/tmp/test.jpg',
      'leaf_type': 'tomato',
      'model_version': '1.0.0',
      'predicted_class_index': 3,
      'predicted_class_name': 'Tomato___Late_blight',
      'confidence': 0.95,
      'all_confidences': jsonEncode([
        0.01,
        0.02,
        0.01,
        0.95,
        0.01,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
      ]),
      'inference_time_ms': 12.5,
      'latitude': 10.762,
      'longitude': 106.660,
      'notes': 'Test note',
      'created_at': now.toIso8601String(),
      'is_synced': 0,
      'synced_at': null,
      'server_id': null,
    };

    test('fromMap creates Prediction correctly', () {
      final p = Prediction.fromMap(sampleMap);
      expect(p.id, 1);
      expect(p.imagePath, '/tmp/test.jpg');
      expect(p.leafType, 'tomato');
      expect(p.predictedClassIndex, 3);
      expect(p.predictedClassName, 'Tomato___Late_blight');
      expect(p.confidence, 0.95);
      expect(p.allConfidences, isNotNull);
      expect(p.allConfidences!.length, 10);
      expect(p.inferenceTimeMs, 12.5);
      expect(p.latitude, 10.762);
      expect(p.longitude, 106.660);
      expect(p.notes, 'Test note');
      expect(p.isSynced, isFalse);
    });

    test('toMap produces correct map', () {
      final p = Prediction(
        id: 5,
        imagePath: '/img.png',
        leafType: 'burmese_grape_leaf',
        modelVersion: '1.0.0',
        predictedClassIndex: 0,
        predictedClassName: 'Anthracnose (Brown Spot)',
        confidence: 0.87,
        createdAt: now,
      );

      final map = p.toMap();
      expect(map['id'], 5);
      expect(map['image_path'], '/img.png');
      expect(map['leaf_type'], 'burmese_grape_leaf');
      expect(map['confidence'], 0.87);
      expect(map['is_synced'], 0);
    });

    test('toMap round-trips through fromMap', () {
      final original = Prediction(
        imagePath: '/photo.jpg',
        leafType: 'tomato',
        modelVersion: '1.0.0',
        predictedClassIndex: 9,
        predictedClassName: 'Tomato___healthy',
        confidence: 0.99,
        allConfidences: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.99],
        createdAt: now,
      );

      final map = original.toMap();
      // Simulate DB: add missing fields
      map['id'] = 1;
      map['is_synced'] = 0;
      final restored = Prediction.fromMap(map);

      expect(restored.leafType, original.leafType);
      expect(restored.predictedClassIndex, original.predictedClassIndex);
      expect(restored.confidence, original.confidence);
      expect(restored.allConfidences!.length, 10);
    });

    test('fromMap handles null optional fields', () {
      final minimal = <String, dynamic>{
        'id': 2,
        'image_path': '/x.jpg',
        'leaf_type': 'tomato',
        'model_version': '1.0.0',
        'predicted_class_index': 0,
        'predicted_class_name': 'Tomato___Bacterial_spot',
        'confidence': 0.5,
        'all_confidences': null,
        'inference_time_ms': null,
        'latitude': null,
        'longitude': null,
        'notes': null,
        'created_at': now.toIso8601String(),
        'is_synced': 1,
        'synced_at': now.toIso8601String(),
        'server_id': 'abc-123',
      };

      final p = Prediction.fromMap(minimal);
      expect(p.allConfidences, isNull);
      expect(p.inferenceTimeMs, isNull);
      expect(p.notes, isNull);
      expect(p.isSynced, isTrue);
      expect(p.serverId, 'abc-123');
    });
  });
}
