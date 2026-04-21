import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/devices/domain/models/device.dart';

/// Helper to create a minimal Device for testing.
Device _makeDevice({
  Map<String, dynamic> desiredConfig = const {},
  Map<String, dynamic>? reportedConfig,
  String? deviceName,
  String hostname = 'jetson-01',
  String status = 'online',
}) {
  return Device(
    id: 1,
    hwId: 'abc123',
    hostname: hostname,
    deviceName: deviceName,
    deviceType: 'jetson',
    status: status,
    desiredConfig: desiredConfig,
    reportedConfig: reportedConfig,
    configVersion: 1,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('Device', () {
    group('displayName', () {
      test('returns deviceName when present', () {
        final d = _makeDevice(deviceName: 'My Jetson');
        expect(d.displayName, 'My Jetson');
      });

      test('returns hostname when deviceName is null', () {
        final d = _makeDevice(deviceName: null, hostname: 'jetson-nano-01');
        expect(d.displayName, 'jetson-nano-01');
      });
    });

    group('isOnline', () {
      test('returns true when status is online', () {
        expect(_makeDevice(status: 'online').isOnline, isTrue);
      });

      test('returns false when status is offline', () {
        expect(_makeDevice(status: 'offline').isOnline, isFalse);
      });

      test('returns false when status is unassigned', () {
        expect(_makeDevice(status: 'unassigned').isOnline, isFalse);
      });
    });

    group('isConfigSynced', () {
      test('returns false when reportedConfig is null', () {
        final d = _makeDevice(
          desiredConfig: {'mode': 'periodic'},
          reportedConfig: null,
        );
        expect(d.isConfigSynced, isFalse);
      });

      test('returns true when configs match exactly', () {
        final config = {'mode': 'periodic', 'interval': 300};
        final d = _makeDevice(
          desiredConfig: config,
          reportedConfig: Map.from(config),
        );
        expect(d.isConfigSynced, isTrue);
      });

      test('returns true when reportedConfig has extra engine_status', () {
        final d = _makeDevice(
          desiredConfig: {'mode': 'periodic', 'interval': 300},
          reportedConfig: {
            'mode': 'periodic',
            'interval': 300,
            'engine_status': {'tomato': 'ready'},
          },
        );
        expect(d.isConfigSynced, isTrue);
      });

      test(
        'returns true when reportedConfig has extra applied_model_versions',
        () {
          final d = _makeDevice(
            desiredConfig: {'mode': 'periodic'},
            reportedConfig: {
              'mode': 'periodic',
              'applied_model_versions': {'tomato': '1.0.0'},
            },
          );
          expect(d.isConfigSynced, isTrue);
        },
      );

      test('returns true when reportedConfig has both runtime fields', () {
        final d = _makeDevice(
          desiredConfig: {
            'mode': 'manual',
            'leaf_types': ['tomato'],
          },
          reportedConfig: {
            'mode': 'manual',
            'leaf_types': ['tomato'],
            'engine_status': {'tomato': 'building'},
            'applied_model_versions': {'tomato': '2.0.0'},
          },
        );
        expect(d.isConfigSynced, isTrue);
      });

      test('returns false when actual config field differs', () {
        final d = _makeDevice(
          desiredConfig: {'mode': 'periodic', 'interval': 300},
          reportedConfig: {
            'mode': 'manual',
            'interval': 300,
            'engine_status': {'tomato': 'ready'},
          },
        );
        expect(d.isConfigSynced, isFalse);
      });

      test('returns false when reportedConfig missing a desired key', () {
        final d = _makeDevice(
          desiredConfig: {'mode': 'periodic', 'interval': 300},
          reportedConfig: {'mode': 'periodic'},
        );
        expect(d.isConfigSynced, isFalse);
      });

      test('returns false when reportedConfig has unknown extra key', () {
        final d = _makeDevice(
          desiredConfig: {'mode': 'periodic'},
          reportedConfig: {'mode': 'periodic', 'unknown_field': true},
        );
        expect(d.isConfigSynced, isFalse);
      });

      test('handles nested maps correctly', () {
        final d = _makeDevice(
          desiredConfig: {
            'mode': 'periodic',
            'model_versions': {'tomato': '1.0.0', 'burmese': '1.0.0'},
          },
          reportedConfig: {
            'mode': 'periodic',
            'model_versions': {'tomato': '1.0.0', 'burmese': '1.0.0'},
            'engine_status': {'tomato': 'ready'},
          },
        );
        expect(d.isConfigSynced, isTrue);
      });

      test('detects nested map differences', () {
        final d = _makeDevice(
          desiredConfig: {
            'model_versions': {'tomato': '2.0.0'},
          },
          reportedConfig: {
            'model_versions': {'tomato': '1.0.0'},
            'engine_status': {'tomato': 'ready'},
          },
        );
        expect(d.isConfigSynced, isFalse);
      });

      test('handles nested lists correctly', () {
        final d = _makeDevice(
          desiredConfig: {
            'leaf_types': ['tomato', 'burmese_grape_leaf'],
          },
          reportedConfig: {
            'leaf_types': ['tomato', 'burmese_grape_leaf'],
            'applied_model_versions': {},
          },
        );
        expect(d.isConfigSynced, isTrue);
      });
    });

    group('fromJson', () {
      test('parses all required fields', () {
        final d = Device.fromJson({
          'id': 42,
          'hw_id': 'sha256hash',
          'hostname': 'jetson-01',
          'device_name': 'Lab Device',
          'device_type': 'jetson',
          'status': 'online',
          'user_id': 'user-uuid',
          'desired_config': {'mode': 'periodic'},
          'reported_config': {'mode': 'periodic'},
          'config_version': 5,
          'last_seen_at': '2026-01-15T10:00:00Z',
          'hw_info': {'model': 'Orin NX'},
          'created_at': '2026-01-01T00:00:00Z',
        });
        expect(d.id, 42);
        expect(d.hwId, 'sha256hash');
        expect(d.hostname, 'jetson-01');
        expect(d.deviceName, 'Lab Device');
        expect(d.deviceType, 'jetson');
        expect(d.status, 'online');
        expect(d.userId, 'user-uuid');
        expect(d.desiredConfig, {'mode': 'periodic'});
        expect(d.reportedConfig, {'mode': 'periodic'});
        expect(d.configVersion, 5);
        expect(d.lastSeenAt, isNotNull);
        expect(d.hwInfo, {'model': 'Orin NX'});
      });

      test('uses defaults for nullable/optional fields', () {
        final d = Device.fromJson({
          'id': 1,
          'hw_id': 'abc',
          'hostname': 'h1',
          'desired_config': {},
          'created_at': '2026-01-01T00:00:00Z',
        });
        expect(d.deviceName, isNull);
        expect(d.deviceType, 'jetson');
        expect(d.status, 'unassigned');
        expect(d.userId, isNull);
        expect(d.reportedConfig, isNull);
        expect(d.configVersion, 0);
        expect(d.lastSeenAt, isNull);
        expect(d.hwInfo, isNull);
      });
    });
  });
}
