/// Device model for Jetson edge devices managed via Supabase.
///
/// Maps to the `public.devices` table (migration 012).
/// Used in the mobile app for read-only device list + schedule editing.
class Device {
  final int id;
  final String hwId;
  final String hostname;
  final String? deviceName;
  final String deviceType;
  final String status;
  final String? userId;
  final Map<String, dynamic> desiredConfig;
  final Map<String, dynamic>? reportedConfig;
  final int configVersion;
  final DateTime? lastSeenAt;
  final Map<String, dynamic>? hwInfo;
  final DateTime createdAt;

  const Device({
    required this.id,
    required this.hwId,
    required this.hostname,
    this.deviceName,
    required this.deviceType,
    required this.status,
    this.userId,
    required this.desiredConfig,
    this.reportedConfig,
    required this.configVersion,
    this.lastSeenAt,
    this.hwInfo,
    required this.createdAt,
  });

  /// Display name: prefer user-set device_name, fallback to hostname.
  String get displayName => deviceName ?? hostname;

  /// Whether the device has acknowledged the latest desired_config.
  /// Strips Jetson-added runtime fields before comparison so that
  /// engine_status and applied_model_versions do not cause false negatives.
  bool get isConfigSynced {
    if (reportedConfig == null) return false;
    final stripped = Map<String, dynamic>.from(reportedConfig!)
      ..remove('engine_status')
      ..remove('applied_model_versions');
    return _jsonEquals(desiredConfig, stripped);
  }

  /// Whether the device is currently reachable.
  bool get isOnline => status == 'online';

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as int,
      hwId: json['hw_id'] as String,
      hostname: json['hostname'] as String,
      deviceName: json['device_name'] as String?,
      deviceType: json['device_type'] as String? ?? 'jetson',
      status: json['status'] as String? ?? 'unassigned',
      userId: json['user_id'] as String?,
      desiredConfig: json['desired_config'] is Map<String, dynamic>
          ? json['desired_config'] as Map<String, dynamic>
          : const {},
      reportedConfig: json['reported_config'] is Map<String, dynamic>
          ? json['reported_config'] as Map<String, dynamic>
          : null,
      configVersion: json['config_version'] as int? ?? 0,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.tryParse(json['last_seen_at'] as String)
          : null,
      hwInfo: json['hw_info'] is Map<String, dynamic>
          ? json['hw_info'] as Map<String, dynamic>
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  /// Deep JSON comparison for config sync detection.
  /// Handles nested maps and lists correctly (Dart's == only does
  /// reference equality for collections).
  static bool _jsonEquals(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
