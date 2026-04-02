import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
});

/// One-shot check at app startup so we don't default to offline.
final _initialConnectivityProvider = FutureProvider<List<ConnectivityResult>>((
  ref,
) {
  return Connectivity().checkConnectivity();
});

final isOnlineProvider = Provider<bool>((ref) {
  final stream = ref.watch(connectivityProvider);
  return stream.when(
    data: (results) => results.any((r) => r != ConnectivityResult.none),
    loading: () {
      // While stream hasn't emitted, use the one-shot check result
      final initial = ref.watch(_initialConnectivityProvider);
      return initial.when(
        data: (results) => results.any((r) => r != ConnectivityResult.none),
        loading: () => true, // assume online until proven otherwise
        error: (_, _) => true,
      );
    },
    error: (e, st) => false,
  );
});
