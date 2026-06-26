// lib/domain/repositories/repositories.dart
//
// Pure abstract interfaces — no Flutter or Firebase imports.
// Mock and Firebase implementations live in data/ and swap
// in main.dart without touching any other file.

import 'dart:async';
import '../models/sensor_data.dart';

// ── Sensor ───────────────────────────────────────────────────
abstract class SensorRepository {
  /// Emits a new list whenever any sensor value changes.
  Stream<List<SensorReading>> get sensorStream;

  /// Snapshot of the most recent history window for [sensorId].
  SensorHistory historyFor(String sensorId);

  /// Fetch history data from Firebase for [sensorId].
  Future<SensorHistory> fetchHistory(String sensorId, {Duration duration});

  void dispose();
}

// ── Device / Actuator ────────────────────────────────────────
abstract class DeviceRepository {
  /// Current list of devices (synchronous snapshot for init).
  List<DeviceState> get currentDevices;

  /// Emits a new list whenever any device state changes.
  Stream<List<DeviceState>> get deviceStream;

  /// All configured automation rules (static / rarely changing).
  List<AutomationRule> get automationRules;

  /// Override a device's control mode.
  void setDeviceStatus(String deviceId, DeviceStatus status, bool isOn);

  void dispose();
}

// ── Alerts ───────────────────────────────────────────────────
abstract class AlertRepository {
  /// Emits the full alert list (active + resolved) on any change.
  Stream<List<AlertRecord>> get alertStream;

  /// Resolve an alert by id.
  Future<void> resolveAlert(String alertId);

  void dispose();
}

// ── System status ────────────────────────────────────────────
abstract class SystemRepository {
  /// Emits connection-status updates.
  Stream<SystemStatus> get statusStream;

  /// Create a new backup record.
  Future<BackupRecord> createBackup();

  /// Fetch all existing backup records.
  Future<List<BackupRecord>> getBackups();

  void dispose();
}

// ── Camera / Growth tracking ─────────────────────────────────
abstract class CameraRepository {
  /// Emits today's [DailyImageSet] whenever a new capture arrives.
  Stream<DailyImageSet> get todayStream;

  /// Synchronous snapshot of today's image set (for first frame).
  DailyImageSet get todayImageSet;

  /// Full ordered history of daily image sets, newest first.
  List<DailyImageSet> get growthTimeline;

  /// Out-of-schedule snapshots taken via manual capture.
  List<PlantSnapshot> get manualSnapshots;

  /// Human-readable label for the next scheduled capture.
  String nextCaptureLabel();

  /// Trigger an immediate out-of-schedule capture.
  PlantSnapshot triggerManualCapture();

  void dispose();
}

// ── Auth ─────────────────────────────────────────────────────
abstract class AuthRepository {
  /// Attempt sign-in with [email] and [password].
  /// Returns `true` on success, throws on failure.
  Future<bool> signIn(String email, String password);
  Future<bool> signUp(String email, String password);


  void dispose();
}

// SystemStatus is defined in ../models/models.dart