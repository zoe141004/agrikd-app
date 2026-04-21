import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/features/devices/domain/models/device.dart';
import 'package:app/providers/devices_provider.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(devicesProvider.notifier).loadDevices());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(devicesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(S.get('my_devices')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(devicesProvider.notifier).loadDevices(),
          ),
        ],
      ),
      body: _buildBody(state, theme),
    );
  }

  Widget _buildBody(DevicesState state, ThemeData theme) {
    if (state.status == DevicesStatus.loading && state.devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == DevicesStatus.error && state.devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                state.errorMessage ?? S.get('error_loading'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () =>
                    ref.read(devicesProvider.notifier).loadDevices(),
                child: Text(S.get('retry')),
              ),
            ],
          ),
        ),
      );
    }

    if (state.devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices_other,
                size: 64,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                S.get('no_devices'),
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                S.get('no_devices_sub'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(devicesProvider.notifier).loadDevices(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: state.devices.length,
        itemBuilder: (context, index) => _DeviceCard(
          device: state.devices[index],
          onEditSchedule: () => _showScheduleEditor(state.devices[index]),
        ),
      ),
    );
  }

  void _showScheduleEditor(Device device) {
    final config = Map<String, dynamic>.from(device.desiredConfig);
    String mode = config['mode'] as String? ?? 'manual';
    int intervalSec = config['interval_seconds'] as int? ?? 86400;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${S.get('edit_schedule')} — ${device.displayName}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.get('capture_mode'),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'manual',
                        label: Text(S.get('manual')),
                        icon: const Icon(Icons.touch_app),
                      ),
                      ButtonSegment(
                        value: 'periodic',
                        label: Text(S.get('periodic')),
                        icon: const Icon(Icons.timer),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (selection) {
                      setModalState(() => mode = selection.first);
                    },
                  ),
                  if (mode == 'periodic') ...[
                    const SizedBox(height: 16),
                    Text(
                      S.get('capture_interval'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    DropdownButton<int>(
                      value: _closestInterval(intervalSec),
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: 60,
                          child: Text(S.get('interval_1m')),
                        ),
                        DropdownMenuItem(
                          value: 300,
                          child: Text(S.get('interval_5m')),
                        ),
                        DropdownMenuItem(
                          value: 900,
                          child: Text(S.get('interval_15m')),
                        ),
                        DropdownMenuItem(
                          value: 1800,
                          child: Text(S.get('interval_30m')),
                        ),
                        DropdownMenuItem(
                          value: 3600,
                          child: Text(S.get('interval_1h')),
                        ),
                        DropdownMenuItem(
                          value: 21600,
                          child: Text(S.get('interval_6h')),
                        ),
                        DropdownMenuItem(
                          value: 86400,
                          child: Text(S.get('interval_24h')),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setModalState(() => intervalSec = v);
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final updated = Map<String, dynamic>.from(config);
                        updated['mode'] = mode;
                        updated['interval_seconds'] = intervalSec;
                        try {
                          await ref
                              .read(devicesProvider.notifier)
                              .updateConfig(device.id, updated);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(S.get('error_saving'))),
                            );
                          }
                        }
                      },
                      child: Text(S.get('save')),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  int _closestInterval(int seconds) {
    const options = [60, 300, 900, 1800, 3600, 21600, 86400];
    return options.reduce(
      (a, b) => (a - seconds).abs() < (b - seconds).abs() ? a : b,
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final Device device;
  final VoidCallback onEditSchedule;

  const _DeviceCard({required this.device, required this.onEditSchedule});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = device.desiredConfig['mode'] as String? ?? 'manual';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEditSchedule,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.developer_board,
                    color: device.isOnline
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.displayName,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          device.hostname,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(label: device.status, isOnline: device.isOnline),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _InfoChip(
                    icon: Icons.timer_outlined,
                    label: mode == 'periodic'
                        ? _formatInterval(
                            device.desiredConfig['interval_seconds'] as int? ??
                                86400,
                          )
                        : S.get('manual'),
                  ),
                  const SizedBox(width: 8),
                  _InfoChip(
                    icon: device.isConfigSynced
                        ? Icons.check_circle_outline
                        : Icons.sync,
                    label: device.isConfigSynced
                        ? S.get('config_synced')
                        : S.get('config_pending'),
                  ),
                  const Spacer(),
                  if (device.lastSeenAt != null)
                    Text(
                      _formatLastSeen(device.lastSeenAt!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatInterval(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }

  String _formatLastSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return S.get('just_now');
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final bool isOnline;

  const _StatusChip({required this.label, required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isOnline
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label.replaceAll('_', ' '),
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
