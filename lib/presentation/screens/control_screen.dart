//control_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:automato/domain/models/sensor_data.dart';
import 'package:automato/presentation/providers/app_state.dart';
import 'package:automato/presentation/theme/app_theme.dart';
import 'package:automato/presentation/widgets/sensor_card.dart';

// ─────────────────────────────────────────────────────────────
// CONTROL SCREEN - RELIABLE DEVICE CONTROL WITH PENDING STATE
// ─────────────────────────────────────────────────────────────

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  bool _isLoading = false;
  String? _loadingDeviceId;
  DateTime? _lastTapTime;

  /// Global lock: prevents ANY taps while processing
  bool get _isGloballyLocked => _isLoading;

  void _setLoading(String deviceId, bool loading) {
    if (!mounted) return;
    setState(() {
      _isLoading = loading;
      _loadingDeviceId = loading ? deviceId : null;
    });
  }

  /// Debounced tap handler with global lock
  Future<void> _handleDeviceTap(
    String deviceId,
    DeviceStatus status,
    bool isOn,
    AppState state,
  ) async {
    // 1. Global lock check
    if (_isGloballyLocked) {
      debugPrint('Tap blocked: global lock active for $_loadingDeviceId');
      return;
    }

    // 2. Debounce: prevent rapid re-taps (300ms cooldown)
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      debugPrint('Tap debounced');
      return;
    }
    _lastTapTime = now;

    _setLoading(deviceId, true);

    try {
      final success = await state.setDeviceStatus(deviceId, status, isOn);

      if (!mounted) return;

      if (!success) {
        // Show error feedback
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to switch ${state.devices.firstWhere((d) => d.id == deviceId).label}. Please try again.',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: AppTheme.statusAlert,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'RETRY',
              textColor: Colors.white,
              onPressed: () => _handleDeviceTap(deviceId, status, isOn, state),
            ),
          ),
        );
      } else {
        // Brief success haptic/visual feedback
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      if (mounted) _setLoading(deviceId, false);
    }
  }

  Future<void> _handleEmergencyShutdown(AppState state) async {
    if (_isGloballyLocked) return;

    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastTapTime = now;

    _setLoading('emergency', true);

    try {
      await state.emergencyShutdown();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'EMERGENCY SHUTDOWN ACTIVATED - ALL RELAYS OFF',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: AppTheme.statusAlert,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Emergency shutdown failed: $e'),
          backgroundColor: AppTheme.statusAlert,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) _setLoading('emergency', false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFFF4F2EE),
          body: SafeArea(
            child: ListView(
              physics: _isGloballyLocked
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              children: [
                // ── Section 1: Device Control ───────────────────────────
                _buildSectionHeader('Device Control'),
                const SizedBox(height: 14),

                ...state.devices.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DeviceCard(
                        device: d,
                        isLoading: _isLoading && _loadingDeviceId == d.id,
                        isGloballyLocked: _isGloballyLocked,
                        isPending: state.isDevicePending(d.id),
                        pendingStatus: state.pendingStatusFor(d.id),
                        onStatusChanged: (status, isOn) =>
                            _handleDeviceTap(d.id, status, isOn, state),
                      ),
                    )),
                const SizedBox(height: 16),

                // ── Emergency Shutdown Button ──
                _buildEmergencyShutdownButton(context, state),
                const SizedBox(height: 32),

                // ── Section 2: Automation Rules ─────────────────────────
                _buildSectionHeader('Automation Rules'),
                const SizedBox(height: 14),

                ...state.automationRules.map((rule) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RuleCard(
                        rule: rule,
                        readings: state.readings,
                      ),
                    )),
              ],
            ),
          ),
        ),

        // Loading overlay (blocks entire screen)
        if (_isGloballyLocked)
          Container(
            color: Colors.black.withOpacity(0.25),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFF132F28),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Sending command...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: AppTheme.ink,
        fontSize: 16,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.2,
      ),
    );
  }

  Widget _buildEmergencyShutdownButton(BuildContext context, AppState state) {
    final activeDevicesCount = state.devices.where((d) => d.isOn).length;
    final isEmergencyLoading = _isLoading && _loadingDeviceId == 'emergency';
    final isDisabled = _isGloballyLocked && !isEmergencyLoading;

    return FloatingCard(
      onTap: isDisabled ? null : () => _showShutdownConfirmation(context, state),
      backgroundColor: isEmergencyLoading
          ? const Color(0xFFE8D5D5)
          : const Color(0xFFFAEAEA),
      borderRadius: 8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isEmergencyLoading
                    ? const Color(0xFFE0C0C0)
                    : const Color(0xFFF5D4D4),
                shape: BoxShape.circle,
              ),
              child: isEmergencyLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.statusAlert,
                      ),
                    )
                  : const Icon(
                      Icons.power_settings_new_rounded,
                      color: AppTheme.statusAlert,
                      size: 24,
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'EMERGENCY SHUTDOWN',
                    style: TextStyle(
                      color: AppTheme.statusAlert,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    activeDevicesCount > 0
                        ? 'Deactivate all $activeDevicesCount running power relays immediately.'
                        : 'Deactivate all power grids & actuators.',
                    style: const TextStyle(
                      color: Color(0xFF8B3A3A),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.statusAlert,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  void _showShutdownConfirmation(BuildContext context, AppState state) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.statusAlert),
              SizedBox(width: 8),
              Text(
                'Confirm Shutdown',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          content: const Text(
            'This action will instantly FORCE OFF all automated relays, water pumps, cooling fans, and lighting grids in the greenhouse.\n\nAre you sure you want to proceed?',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            TextButton(
              onPressed: _isGloballyLocked ? null : () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.inkFaint, fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton(
              onPressed: _isGloballyLocked
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await _handleEmergencyShutdown(state);
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.statusAlert,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text(
                'FORCE STOP',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── DEVICE CARD ──────────────────────────────────────────────
class _DeviceCard extends StatelessWidget {
  final DeviceState device;
  final bool isLoading;
  final bool isGloballyLocked;
  final bool isPending;
  final DeviceStatus? pendingStatus;
  final void Function(DeviceStatus, bool) onStatusChanged;

  const _DeviceCard({
    required this.device,
    required this.isLoading,
    required this.isGloballyLocked,
    required this.isPending,
    required this.pendingStatus,
    required this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isOn = device.isOn;
    final isDisabled = isGloballyLocked && !isLoading;

    // Show pending state visually
    final bool showPending = isPending;
    final DeviceStatus displayStatus = pendingStatus ?? device.status;

    return FloatingCard(
      backgroundColor: Colors.white,
      borderRadius: 8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Row 1: Icon, Title and Current State Pill Badge
            Row(
              children: [
                Container(
                  width: 42,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isOn && !showPending
                        ? const Color(0xFFEAEFE4)
                        : const Color(0xFFF4F2EE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: isLoading || showPending
                      ? const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF132F28),
                            ),
                          ),
                        )
                      : Icon(
                          _iconData(device.icon),
                          color: isOn ? AppTheme.statusNormal : AppTheme.inkFaint,
                          size: 20,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.label,
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (showPending)
                        const Text(
                          'Syncing...',
                          style: TextStyle(
                            color: AppTheme.inkFaint,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      else if (device.triggerReason != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          device.triggerReason!,
                          style: const TextStyle(
                            color: AppTheme.inkFaint,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: showPending
                        ? const Color(0xFFE8E8E8)
                        : (isOn ? const Color(0xFFEAEFE4) : const Color(0xFFF4F2EE)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    showPending ? 'SYNCING' : (isOn ? 'ACTIVE' : 'OFF'),
                    style: TextStyle(
                      color: showPending
                          ? AppTheme.inkFaint
                          : (isOn ? AppTheme.statusNormal : AppTheme.inkFaint),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Row 2: Mode Selector Chips
            Row(
              children: [
                Expanded(
                  child: _ModeChip(
                    label: 'AUTO',
                    selected: displayStatus == DeviceStatus.auto,
                    isLoading: isLoading,
                    isDisabled: isDisabled || showPending,
                    onTap: () => onStatusChanged(DeviceStatus.auto, isOn),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeChip(
                    label: 'ON',
                    selected: displayStatus == DeviceStatus.manualOn,
                    color: AppTheme.statusNormal,
                    isLoading: isLoading,
                    isDisabled: isDisabled || showPending,
                    onTap: () => onStatusChanged(DeviceStatus.manualOn, true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeChip(
                    label: 'OFF',
                    selected: displayStatus == DeviceStatus.manualOff,
                    color: AppTheme.statusAlert,
                    isLoading: isLoading,
                    isDisabled: isDisabled || showPending,
                    onTap: () => onStatusChanged(DeviceStatus.manualOff, false),
                  ),
                ),
              ],
            ),

            if (device.lastTriggered != null && !showPending) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.access_time_rounded,
                    size: 13,
                    color: AppTheme.inkFaint,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Last active: ${_timeAgo(device.lastTriggered!)}',
                    style: const TextStyle(
                      color: AppTheme.inkFaint,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconData(String name) {
    switch (name) {
      case 'air':
        return Icons.air_rounded;
      case 'cyclone':
        return Icons.cyclone_rounded;
      case 'water':
        return Icons.water_drop_rounded;
      case 'light_mode':
        return Icons.light_mode_rounded;
      default:
        return Icons.power_rounded;
    }
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

// ── MODE CHIP ─────────────────────────────────────────────────
class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final bool isLoading;
  final bool isDisabled;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.selected,
    this.color,
    required this.isLoading,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFF132F28);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: (isLoading || isDisabled) ? null : onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? c.withOpacity(0.12) : const Color(0xFFF4F2EE),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: isLoading && selected
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c,
                    ),
                  )
                : Text(
                    label,
                    style: TextStyle(
                      color: isDisabled
                          ? AppTheme.inkFaint.withOpacity(0.4)
                          : (selected ? c : AppTheme.inkFaint),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ── AUTOMATION RULE CARD ─────────────────────────────────────
class _RuleCard extends StatelessWidget {
  final AutomationRule rule;
  final List<SensorReading> readings;

  const _RuleCard({
    required this.rule,
    required this.readings,
  });

  @override
  Widget build(BuildContext context) {
    final sensor = readings.where((r) => r.id == rule.sensorId).firstOrNull;
    final isTriggered =
        sensor != null && sensor.status != SensorStatus.normal;

    return FloatingCard(
      backgroundColor: Colors.white,
      borderRadius: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isTriggered ? AppTheme.statusWarning : const Color(0xFF132F28),
                boxShadow: isTriggered
                    ? [
                        BoxShadow(
                          color: AppTheme.statusWarning.withOpacity(0.3),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
            ),
            Expanded(
              child: Text(
                rule.actionDescription,
                style: const TextStyle(
                  color: AppTheme.inkMid,
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}