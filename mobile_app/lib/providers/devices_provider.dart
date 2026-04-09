import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/config/supabase_config.dart';
import 'package:app/features/devices/domain/models/device.dart';

/// State for the devices list.
enum DevicesStatus { idle, loading, success, error }

class DevicesState {
  final DevicesStatus status;
  final List<Device> devices;
  final String? errorMessage;

  const DevicesState({
    this.status = DevicesStatus.idle,
    this.devices = const [],
    this.errorMessage,
  });

  DevicesState copyWith({
    DevicesStatus? status,
    List<Device>? devices,
    String? errorMessage,
  }) {
    return DevicesState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      errorMessage: errorMessage,
    );
  }
}

class DevicesNotifier extends StateNotifier<DevicesState> {
  DevicesNotifier() : super(const DevicesState());

  /// Fetch devices assigned to the current user (RLS enforced).
  Future<void> loadDevices() async {
    state = state.copyWith(status: DevicesStatus.loading);

    try {
      if (!SupabaseConfig.isInitialized) {
        state = state.copyWith(
          status: DevicesStatus.error,
          errorMessage: 'Supabase not initialized',
        );
        return;
      }

      final response = await SupabaseConfig.client
          .from('devices')
          .select()
          .order('created_at', ascending: false);

      final devices = (response as List)
          .map((e) => Device.fromJson(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(status: DevicesStatus.success, devices: devices);
    } catch (e) {
      state = state.copyWith(
        status: DevicesStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Update the desired_config for a device (user can edit schedule).
  Future<void> updateConfig(int deviceId, Map<String, dynamic> config) async {
    try {
      await SupabaseConfig.client
          .from('devices')
          .update({'desired_config': config})
          .eq('id', deviceId);

      // Refresh the list to reflect the new config_version
      await loadDevices();
    } catch (e) {
      state = state.copyWith(
        status: DevicesStatus.error,
        errorMessage: e.toString(),
      );
    }
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier, DevicesState>((
  ref,
) {
  return DevicesNotifier();
});
