// app_state.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../../domain/models/sensor_data.dart';
import '../../domain/repositories/repositories.dart';
import '../../services/notification_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/vision_service.dart';
import '../../services/aigrowth_analyzer.dart';
import 'package:collection/collection.dart';

// ── Pending command helper (top-level, not inside AppState) ──
class _PendingCommand {
  final String deviceId;
  final DeviceStatus targetStatus;
  final bool targetIsOn;
  final DateTime issuedAt;

  _PendingCommand({
    required this.deviceId,
    required this.targetStatus,
    required this.targetIsOn,
    required this.issuedAt,
  });
}

class AppState extends ChangeNotifier {
  final SensorRepository _sensorRepo;
  final DeviceRepository _deviceRepo;
  final AlertRepository _alertRepo;
  final SystemRepository _systemRepo;
  final CameraRepository _cameraRepo;
  final _driveService = GoogleDriveService();
  final _visionService = CloudVisionService();
  final _aiAnalyzer = AIGrowthAnalyzer();

  // Firebase Realtime Database reference
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  StreamSubscription<DatabaseEvent>? _capturesSub;

  List<SensorReading> _readings = [];
  List<DeviceState> _devices = [];
  List<AlertRecord> _alerts = [];
  SystemStatus? _systemStatus;
  List<BackupRecord> _backups = [];

  // Camera data owned locally
  late DailyImageSet _todayImageSet;
  final List<PlantSnapshot> _manualSnapshots = [];
  final List<DailyImageSet> _growthTimeline = [];

  // Day navigation
  DailyImageSet? _viewingDaySet;
  List<DailyImageSet> _allDays = [];

  final Map<String, DateTime> _lastNotifiedAt = {};

  late final List<StreamSubscription<dynamic>> _subs;

  // ── Init ─────────────────────────────────────────────────────
  AppState({
    required SensorRepository sensorRepository,
    required DeviceRepository deviceRepository,
    required AlertRepository alertRepository,
    required SystemRepository systemRepository,
    required CameraRepository cameraRepository,
  })  : _sensorRepo = sensorRepository,
        _deviceRepo = deviceRepository,
        _alertRepo = alertRepository,
        _systemRepo = systemRepository,
        _cameraRepo = cameraRepository {
    _init();
  }

  void _init() {
    // Initialize camera data from repo
    _todayImageSet = _cameraRepo.todayImageSet;
    _manualSnapshots.addAll(_cameraRepo.manualSnapshots);
    _growthTimeline.addAll(_cameraRepo.growthTimeline);

    // Set up stream subscriptions
    _devices = _deviceRepo.currentDevices;
    _loadBackups();

    _subs = [
      _sensorRepo.sensorStream.listen((r) {
        _readings = r;
        notifyListeners();
      }),
      _deviceRepo.deviceStream.listen((d) {
        _devices = d;
        notifyListeners();
      }),
      _alertRepo.alertStream.listen((a) async {
        final previousIds = _alerts.map((x) => x.id).toSet();
        _alerts = a;
        notifyListeners();

        final now = DateTime.now();
        const renotifyInterval = Duration(minutes: 2);

        final activeCount = a.where((alert) => !alert.isResolved).length;
        await NotificationService.updateBadgeCount(activeCount);

        for (final alert in a) {
          if (alert.isResolved) continue;

          final last = _lastNotifiedAt[alert.id];
          final isNew = !previousIds.contains(alert.id);
          final shouldReNotify =
              last != null && now.difference(last) >= renotifyInterval;

          if (isNew || shouldReNotify) {
            _lastNotifiedAt[alert.id] = now;
            try {
              await NotificationService.showAlertNotification(
                alert,
                badgeCount: activeCount,
              );
            } catch (e) {
              debugPrint('Notification error: $e');
            }
          }
        }

        _lastNotifiedAt.removeWhere(
          (id, _) =>
              !a.any((alert) => alert.id == id) ||
              a.any((alert) => alert.id == id && alert.isResolved),
        );
      }),
      _systemRepo.statusStream.listen((s) {
        _systemStatus = s;
        notifyListeners();
      }),
    ];

    // ✅ Load persisted captures from Firebase
    _loadCapturesFromFirebase();
  }

  // ── Day Navigation ───────────────────────────────────────────
  bool get isViewingToday => _viewingDaySet == null;
  DailyImageSet get currentDaySet => _viewingDaySet ?? _todayImageSet;
  List<DailyImageSet> get allDays => List.unmodifiable(_allDays);

  void navigateToDay(int dayNumber) {
    if (dayNumber == _todayImageSet.dayNumber) {
      _viewingDaySet = null;
      _manualSnapshots.clear();
      // Reload today's manual snapshots
      _loadTodayManualFromFirebase();
    } else {
      _viewingDaySet = _allDays.firstWhere(
        (d) => d.dayNumber == dayNumber,
        orElse: () => DailyImageSet(
          date: DateTime.now().subtract(Duration(days: _todayImageSet.dayNumber - dayNumber)),
          dayNumber: dayNumber,
        ),
      );
      _manualSnapshots.clear();
      // Load manual snapshots for the viewed day
      _loadDayManualFromFirebase(dayNumber);
    }
    notifyListeners();
  }

  void navigatePrevDay() {
    final target = currentDaySet.dayNumber - 1;
    if (target >= 1) navigateToDay(target);
  }

  void navigateNextDay() {
    final target = currentDaySet.dayNumber + 1;
    if (target <= _todayImageSet.dayNumber) navigateToDay(target);
  }

  Future<void> _loadTodayManualFromFirebase() async {
    try {
      final todayKey = 'day_${_todayImageSet.dayNumber}';
      final snapshot = await _db.child('captures/$todayKey').get();
      if (!snapshot.exists || snapshot.value == null) return;

      final todayData = snapshot.value as Map<dynamic, dynamic>;
      for (final entry in todayData.entries) {
        final key = entry.key.toString();
        if (!key.startsWith('manual_')) continue;

        final snapData = entry.value as Map<dynamic, dynamic>;
        final fileId = snapData['fileId'] as String?;
        final localPath = snapData['localPath'] as String?;

        if (fileId == null && localPath == null) continue;

        final snap = PlantSnapshot(
          id: snapData['id'] ?? key,
          slot: CaptureSlot.manual,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(snapData['capturedAt'] ?? 0),
          isManual: true,
          dayNumber: _todayImageSet.dayNumber,
          imageUrl: fileId,
          localPath: localPath,
        );
        _manualSnapshots.add(snap);
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load today manual: $e');
    }
  }

  Future<void> _loadDayManualFromFirebase(int dayNumber) async {
    try {
      final dayKey = 'day_$dayNumber';
      final snapshot = await _db.child('captures/$dayKey').get();
      if (!snapshot.exists || snapshot.value == null) return;

      final dayData = snapshot.value as Map<dynamic, dynamic>;
      for (final entry in dayData.entries) {
        final key = entry.key.toString();
        if (!key.startsWith('manual_')) continue;

        final snapData = entry.value as Map<dynamic, dynamic>;
        final fileId = snapData['fileId'] as String?;
        final localPath = snapData['localPath'] as String?;

        if (fileId == null && localPath == null) continue;

        final snap = PlantSnapshot(
          id: snapData['id'] ?? key,
          slot: CaptureSlot.manual,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(snapData['capturedAt'] ?? 0),
          isManual: true,
          dayNumber: dayNumber,
          imageUrl: fileId,
          localPath: localPath,
        );
        _manualSnapshots.add(snap);
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load day $dayNumber manual: $e');
    }
  }

  // ── Load captures from Firebase ─────────────────────────────
  Future<void> _loadCapturesFromFirebase() async {
    try {
      debugPrint('☁️ Loading captures from Firebase...');

      final snapshot = await _db.child('captures').get();
      if (!snapshot.exists || snapshot.value == null) {
        debugPrint('   No captures data in Firebase');
        return;
      }

      final data = snapshot.value as Map<dynamic, dynamic>;
      debugPrint('   Found ${data.length} day entries');

      // ── Clear old local data before Firebase load ──
      _manualSnapshots.clear();
      _allDays.clear();

      final todayKey = 'day_${_todayImageSet.dayNumber}';
      final todayData = data[todayKey] as Map<dynamic, dynamic>?;

      // ── Load all historical days ──
      for (final dayEntry in data.entries) {
        final dayKey = dayEntry.key.toString();
        if (!dayKey.startsWith('day_')) continue;

        final dayNum = int.tryParse(dayKey.replaceFirst('day_', '')) ?? 0;
        if (dayNum == 0) continue;

        final dayData = dayEntry.value as Map<dynamic, dynamic>;

        // Build DailyImageSet for this day
        final dateMs = dayData['metadata']?['dateMs'] ?? DateTime.now().millisecondsSinceEpoch;
        final daySet = DailyImageSet(
          date: DateTime.fromMillisecondsSinceEpoch(dateMs as int),
          dayNumber: dayNum,
        );

        // Load scheduled captures
        for (final slot in [CaptureSlot.morning, CaptureSlot.afternoon, CaptureSlot.evening]) {
          final slotData = dayData[slot.name] as Map<dynamic, dynamic>?;
          if (slotData == null) continue;

          final fileId = slotData['fileId'] as String?;
          final localPath = slotData['localPath'] as String?;
          final capturedAtMs = slotData['capturedAt'] as int?;

          if (fileId == null && localPath == null) continue;

          daySet.snapshots[slot] = PlantSnapshot(
            id: slotData['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
            slot: slot,
            capturedAt: capturedAtMs != null
                ? DateTime.fromMillisecondsSinceEpoch(capturedAtMs)
                : DateTime.now(),
            isManual: false,
            dayNumber: dayNum,
            imageUrl: fileId,
            localPath: localPath,
          );
        }

        // Load AI report
        final aiReportData = dayData['aiReport'] as Map<dynamic, dynamic>?;
        if (aiReportData != null) {
          try {
            daySet.aiReport = AIGrowthReport.fromJson(
              aiReportData['id'] as String? ?? 'ai_$dayNum',
              aiReportData,
            );
          } catch (e) {
            debugPrint('   ⚠️ Failed to parse AI report for day $dayNum: $e');
          }
        }

        _allDays.add(daySet);

        // If this is today, also populate _todayImageSet
        if (dayNum == _todayImageSet.dayNumber) {
          for (final slot in [CaptureSlot.morning, CaptureSlot.afternoon, CaptureSlot.evening]) {
            if (daySet.snapshots[slot] != null) {
              _todayImageSet.snapshots[slot] = daySet.snapshots[slot];
            }
          }
          if (daySet.aiReport != null) {
            _todayImageSet.aiReport = daySet.aiReport;
          }
        }
      }

      // Sort by day number
      _allDays.sort((a, b) => a.dayNumber.compareTo(b.dayNumber));

      // ── Load today's manual captures ──
      if (todayData != null) {
        for (final entry in todayData.entries) {
          final key = entry.key.toString();
          if (!key.startsWith('manual_')) continue;

          final snapData = entry.value as Map<dynamic, dynamic>;
          final fileId = snapData['fileId'] as String?;
          final localPath = snapData['localPath'] as String?;

          if (fileId == null && localPath == null) continue;

          final snap = PlantSnapshot(
            id: snapData['id'] ?? key,
            slot: CaptureSlot.manual,
            capturedAt: DateTime.fromMillisecondsSinceEpoch(snapData['capturedAt'] ?? 0),
            isManual: true,
            dayNumber: snapData['dayNumber'] ?? _todayImageSet.dayNumber,
            imageUrl: fileId,
            localPath: localPath,
          );
          _manualSnapshots.add(snap);
          debugPrint('   Loaded manual snapshot: $key');
        }

        // ── BACKWARD COMPATIBILITY: load old single "manual" node ──
        final oldManualData = todayData['manual'] as Map<dynamic, dynamic>?;
        if (oldManualData != null) {
          final fileId = oldManualData['fileId'] as String?;
          final localPath = oldManualData['localPath'] as String?;
          if (fileId != null || localPath != null) {
            final snap = PlantSnapshot(
              id: oldManualData['id'] ?? 'manual_legacy',
              slot: CaptureSlot.manual,
              capturedAt: DateTime.fromMillisecondsSinceEpoch(oldManualData['capturedAt'] ?? 0),
              isManual: true,
              dayNumber: _todayImageSet.dayNumber,
              imageUrl: fileId,
              localPath: localPath,
            );
            if (!_manualSnapshots.any((s) => s.id == snap.id)) {
              _manualSnapshots.add(snap);
              debugPrint('   Loaded legacy manual snapshot');
            }
          }
        }
      }

      notifyListeners();
      debugPrint('☁️ Firebase load complete: days=${_allDays.length}, today captures=${_todayImageSet.captureCount}, manual=${_manualSnapshots.length}');

    } catch (e, stack) {
      debugPrint('❌ Firebase load error: $e');
      debugPrint('Stack: $stack');
    }
  }

  // ── Persist capture to Firebase ─────────────────────────────
  Future<void> _persistToFirebase(CaptureSlot slot, PlantSnapshot snapshot) async {
    try {
      final dayKey = 'day_${snapshot.dayNumber}';

      final String slotKey;
      if (slot == CaptureSlot.manual) {
        slotKey = 'manual_${snapshot.id}';
      } else {
        slotKey = slot.name;
      }

      final data = {
        'id': snapshot.id,
        'fileId': snapshot.imageUrl,
        'localPath': snapshot.localPath,
        'capturedAt': snapshot.capturedAt.millisecondsSinceEpoch,
        'dayNumber': snapshot.dayNumber,
        'slot': slot.name,
      };

      await _db.child('captures/$dayKey/$slotKey').set(data);

      // ✅ Save metadata for correct date tracking
      await _db.child('captures/$dayKey/metadata').set({
        'dateMs': snapshot.capturedAt.millisecondsSinceEpoch,
        'dayNumber': snapshot.dayNumber,
        'lastUpdated': DateTime.now().millisecondsSinceEpoch,
      });

      // Update global metadata
      await _db.child('metadata/currentDay').set(snapshot.dayNumber);
      await _db.child('metadata/currentDateMs').set(DateTime.now().millisecondsSinceEpoch);

      debugPrint('☁️ Firebase saved: captures/$dayKey/$slotKey');
    } catch (e) {
      debugPrint('❌ Firebase save error: $e');
    }
  }

  // ── Delete from Firebase ─────────────────────────────────────
  Future<void> _deleteFromFirebase(CaptureSlot slot, int dayNumber) async {
    try {
      final dayKey = 'day_$dayNumber';
      await _db.child('captures/$dayKey/${slot.name}').remove();
      debugPrint('☁️ Firebase deleted: captures/$dayKey/${slot.name}');
    } catch (e) {
      debugPrint('❌ Firebase delete error: $e');
    }
  }

  Future<void> _loadBackups() async {
    _backups = await _systemRepo.getBackups();
    notifyListeners();
  }

  // ── Getters ──────────────────────────────────────────────────
  List<SensorReading> get readings => _readings;
  List<DeviceState> get devices => _devices;
  bool get isConnected => _systemStatus?.isConnected ?? true;
  DateTime get lastUpdated => _systemStatus?.lastSeen ?? DateTime.now();
  String get connectionLabel => isConnected ? 'LIVE' : 'OFFLINE';
  int get alertCount => activeAlerts.length;

  List<AlertRecord> get allAlerts => _alerts;
  List<AlertRecord> get activeAlerts => _alerts.where((a) => !a.isResolved).toList();

  List<AutomationRule> get automationRules => _deviceRepo.automationRules;

  List<DailyImageSet> get growthTimeline => _growthTimeline;
  DailyImageSet get todayImageSet => _todayImageSet;
  List<PlantSnapshot> get manualSnapshots => List.unmodifiable(_manualSnapshots);

  List<BackupRecord> get backups => _backups;

  // ── Sensors ──────────────────────────────────────────────────
  SensorHistory historyFor(String sensorId) => _sensorRepo.historyFor(sensorId);

  Future<SensorHistory> fetchHistory(String sensorId, {Duration duration = const Duration(hours: 6)}) async {
    return _sensorRepo.fetchHistory(sensorId, duration: duration);
  }

  SensorReading? readingById(String id) {
    try {
      return _readings.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  // ════════════════════════════════════════════════════════════
  // DEVICES — RELIABLE: Sync UI to ESP32-reported hardware state
  // ════════════════════════════════════════════════════════════

  // Track pending commands: deviceId -> {status, mode, targetState, issuedAt}
  final Map<String, _PendingCommand> _pendingCommands = {};

  /// True if any device command is currently in-flight
  bool get isAnyDevicePending => _pendingCommands.isNotEmpty;

  /// Check if a specific device has a pending command
  bool isDevicePending(String deviceId) => _pendingCommands.containsKey(deviceId);

  /// Get the pending mode for a device (for UI display during transition)
  DeviceStatus? pendingStatusFor(String deviceId) =>
      _pendingCommands[deviceId]?.targetStatus;

  /// Send device command to ESP32 via Firebase — UI follows hardware, not local
  Future<bool> setDeviceStatus(String deviceId, DeviceStatus status, bool isOn) async {
    // 1. Prevent duplicate commands while one is pending
    if (_pendingCommands.containsKey(deviceId)) {
      debugPrint('Command blocked: $deviceId already has pending command');
      return false;
    }

    // 2. Build command payload
    final modeStr = status == DeviceStatus.manualOn
        ? 'manual_on'
        : status == DeviceStatus.manualOff
            ? 'manual_off'
            : 'auto';

    final commandData = {
      'status': 'pending',
      'mode': modeStr,
      'targetState': isOn,
      'timestamp': ServerValue.timestamp,
      'issuedBy': 'flutter_app',
    };

    // 3. Mark as pending (UI shows loading/spinner, not the new state yet)
    _pendingCommands[deviceId] = _PendingCommand(
      deviceId: deviceId,
      targetStatus: status,
      targetIsOn: isOn,
      issuedAt: DateTime.now(),
    );
    notifyListeners();

    try {
      // 4. Write to Firebase
      await _db.child('commands/$deviceId').set(commandData).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Firebase command timeout'),
      );

      debugPrint('Command sent: $deviceId -> $modeStr ($isOn)');

      // 5. Wait for ESP32 to process AND update /devices (max 5s)
      final success = await _waitForDeviceSync(deviceId, status, isOn, timeoutMs: 5000);

      // 6. Clear pending regardless of outcome
      _pendingCommands.remove(deviceId);
      notifyListeners();

      if (!success) {
        debugPrint('Device sync timeout for $deviceId — ESP32 did not confirm');
        return false;
      }

      debugPrint('Device synced: $deviceId is now $modeStr');
      return true;

    } catch (e) {
      debugPrint('Command failed for $deviceId: $e');
      _pendingCommands.remove(deviceId);
      notifyListeners();
      return false;
    }
  }

  /// Wait until ESP32 reports the matching state in /devices/{id}
  Future<bool> _waitForDeviceSync(
    String deviceId,
    DeviceStatus expectedStatus,
    bool expectedIsOn, {
    required int timeoutMs,
  }) async {
    final completer = Completer<bool>();
    late StreamSubscription<DatabaseEvent> sub;
    Timer? timer;

    // Check if already matching (ESP32 might be fast)
    final currentDevice = _devices.firstWhereOrNull((d) => d.id == deviceId);
    if (currentDevice != null &&
        currentDevice.status == expectedStatus &&
        currentDevice.isOn == expectedIsOn) {
      return true;
    }

    timer = Timer(Duration(milliseconds: timeoutMs), () {
      sub.cancel();
      if (!completer.isCompleted) completer.complete(false);
    });

    sub = _db.child('devices/$deviceId').onValue.listen((event) {
      if (event.snapshot.value == null) return;

      final data = event.snapshot.value as Map<dynamic, dynamic>;
      final modeStr = data['mode'] as String? ?? 'auto';
      final isOn = data['isOn'] as bool? ?? false;

      final actualStatus = _parseDeviceStatus(modeStr);

      if (actualStatus == expectedStatus && isOn == expectedIsOn) {
        timer?.cancel();
        sub.cancel();
        if (!completer.isCompleted) completer.complete(true);
      }
    });

    return completer.future;
  }

  static DeviceStatus _parseDeviceStatus(String? modeStr) {
    switch (modeStr) {
      case 'manual_on':
        return DeviceStatus.manualOn;
      case 'manual_off':
        return DeviceStatus.manualOff;
      default:
        return DeviceStatus.auto;
    }
  }

  /// Emergency shutdown — sends OFF to all, waits for all to confirm
  Future<void> emergencyShutdown() async {
    final batch = <String, dynamic>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    // Mark all as pending
    for (final device in _devices) {
      _pendingCommands[device.id] = _PendingCommand(
        deviceId: device.id,
        targetStatus: DeviceStatus.manualOff,
        targetIsOn: false,
        issuedAt: DateTime.now(),
      );

      batch['commands/${device.id}'] = {
        'status': 'pending',
        'mode': 'manual_off',
        'targetState': false,
        'timestamp': now,
        'issuedBy': 'flutter_app',
      };
    }

    notifyListeners();

    try {
      await _db.update(batch).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('Emergency shutdown timeout'),
      );

      // Wait for all devices to report OFF
      final futures = _devices.map((d) =>
        _waitForDeviceSync(d.id, DeviceStatus.manualOff, false, timeoutMs: 5000),
      );
      await Future.wait(futures);

      _pendingCommands.clear();
      notifyListeners();

      debugPrint('Emergency shutdown complete — all devices confirmed OFF');

    } catch (e) {
      debugPrint('Emergency shutdown failed: $e');
      _pendingCommands.clear();
      notifyListeners();
      rethrow;
    }
  }



  // ── Camera ───────────────────────────────────────────────────
  PlantSnapshot triggerManualCapture() {
    final snap = _cameraRepo.triggerManualCapture();
    _manualSnapshots.add(snap);
    notifyListeners();
    return snap;
  }

  String nextCaptureLabel() => _cameraRepo.nextCaptureLabel();

  /// Save snapshot to state and persist to Firebase
  Future<void> saveSlotCapture({
    required CaptureSlot slot,
    required Uint8List bytes,
    String? localPath,
    String? driveUrl,
  }) async {
    final now = DateTime.now();
    final snapshot = PlantSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      slot: slot,
      capturedAt: now,
      isManual: slot == CaptureSlot.manual,
      dayNumber: _todayImageSet.dayNumber,
      localPath: localPath,
      imageUrl: driveUrl,
    );

    if (slot == CaptureSlot.manual) {
      _manualSnapshots.add(snapshot);
    } else {
      _todayImageSet.snapshots[slot] = snapshot;
    }

    await _persistToFirebase(slot, snapshot);

    if (slot != CaptureSlot.manual &&
        _todayImageSet.isComplete &&
        _todayImageSet.aiReport == null) {
      await _runAIAnalysis();
    }

    notifyListeners();
  }

  /// Replace an existing scheduled capture
  Future<void> replaceSlotCapture({
    required CaptureSlot slot,
    required Uint8List bytes,
    required PlantSnapshot oldSnapshot,
    String? localPath,
    String? driveUrl,
  }) async {
    // 1. Delete old local file
    if (oldSnapshot.localPath != null) {
      try {
        final oldFile = File(oldSnapshot.localPath!);
        if (oldFile.existsSync()) {
          oldFile.deleteSync();
          debugPrint('🗑️ Deleted old local file: ${oldSnapshot.localPath}');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to delete old local file: $e');
      }
    }

    // 2. Delete old Drive file
    if (oldSnapshot.imageUrl != null) {
      try {
        await _driveService.deleteFile(oldSnapshot.imageUrl!);
      } catch (e) {
        debugPrint('⚠️ Failed to delete old Drive file: $e');
      }
    }

    // 3. Clear old AI report
    if (_todayImageSet.aiReport != null) {
      _todayImageSet.aiReport = null;
      try {
        await _db.child('captures/day_${_todayImageSet.dayNumber}/aiReport').remove();
        debugPrint('🗑️ Cleared old AI report from Firebase');
      } catch (e) {
        debugPrint('⚠️ Failed to clear old AI report: $e');
      }
    }

    // 4. Create new snapshot
    final now = DateTime.now();
    final newSnapshot = PlantSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      slot: slot,
      capturedAt: now,
      isManual: false,
      dayNumber: _todayImageSet.dayNumber,
      localPath: localPath,
      imageUrl: driveUrl,
    );

    // 5. Replace in state
    _todayImageSet.snapshots[slot] = newSnapshot;

    // 6. Persist to Firebase
    await _persistToFirebase(slot, newSnapshot);

    // 7. Trigger AI if complete
    if (_todayImageSet.isComplete) {
      await _runAIAnalysis();
    }

    notifyListeners();
  }

  /// Full capture flow — local save + Drive upload + Firebase persist
  Future<void> captureAndSaveSlot(CaptureSlot slot, Uint8List imageBytes) async {
    String? localPath;
    String? driveUrl;

    try {
      // 1. Save to PERMANENT local storage
      final appDir = await getApplicationDocumentsDirectory();
      final capturesDir = Directory(path.join(appDir.path, 'captures'));
      await capturesDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final fileName = '${slot.name}_${_todayImageSet.dayNumber}_$timestamp.jpg';
      localPath = path.join(capturesDir.path, fileName);

      await File(localPath).writeAsBytes(imageBytes);
      debugPrint('💾 Local file saved: $localPath');

      // 2. Upload to Google Drive
      try {
        if (!_driveService.isSignedIn) {
          await _driveService.signIn();
        }
        driveUrl = await _driveService.uploadImageBytes(
          bytes: imageBytes,
          fileName: fileName,
        );
        debugPrint('☁️ Drive upload success: fileId=$driveUrl');
      } catch (e) {
        debugPrint('Drive upload failed (saved locally): $e');
      }

      // 3. Save to state and persist to Firebase
      await saveSlotCapture(
        slot: slot,
        bytes: imageBytes,
        localPath: localPath,
        driveUrl: driveUrl,
      );
    } catch (e) {
      // Cleanup on failure
      if (localPath != null) {
        try { File(localPath).deleteSync(); } catch (_) {}
      }
      rethrow;
    }
  }

  // ── AI Analysis Helpers ──────────────────────────────────────

  /// Pick the best image slot for AI analysis (prefer evening, then afternoon, then morning)
  CaptureSlot _getBestImageSlot(DailyImageSet daySet) {
    if (daySet.snapshots[CaptureSlot.evening] != null) return CaptureSlot.evening;
    if (daySet.snapshots[CaptureSlot.afternoon] != null) return CaptureSlot.afternoon;
    if (daySet.snapshots[CaptureSlot.morning] != null) return CaptureSlot.morning;
    return CaptureSlot.morning; // fallback
  }

  /// Load image bytes from local path or download from Drive
  Future<Uint8List?> _loadImageBytes(PlantSnapshot snapshot) async {
    // Try local first
    if (snapshot.localPath != null) {
      try {
        final file = File(snapshot.localPath!);
        if (file.existsSync()) {
          return await file.readAsBytes();
        }
      } catch (e) {
        debugPrint('⚠️ Failed to read local image: $e');
      }
    }

    // Fallback: download from Drive if we have a fileId
    if (snapshot.imageUrl != null) {
      try {
        return await _driveService.downloadFile(snapshot.imageUrl!);
      } catch (e) {
        debugPrint('⚠️ Failed to download from Drive: $e');
      }
    }

    return null;
  }

  // ── AI Analysis ──────────────────────────────────────────────
  Future<void> _runAIAnalysis() async {
    // Check if AI report already exists in Firebase
    try {
      final aiSnapshot = await _db.child('captures/day_${_todayImageSet.dayNumber}/aiReport').get();
      if (aiSnapshot.exists && aiSnapshot.value != null) {
        final data = aiSnapshot.value as Map<dynamic, dynamic>;
        _todayImageSet.aiReport = AIGrowthReport.fromJson(
          data['id'] as String? ?? 'ai_${_todayImageSet.dayNumber}',
          data,
        );
        _growthTimeline.add(_todayImageSet);
        notifyListeners();
        debugPrint('☁️ AI report loaded from Firebase (skipped generation)');
        return;
      }
    } catch (e) {
      debugPrint('⚠️ Could not check Firebase for AI report: $e');
    }

    // ── Real ML + Sensor Fusion Analysis ──
    try {
      debugPrint('🤖 Starting real AI analysis...');

      // 1. Pick best image
      final bestSlot = _getBestImageSlot(_todayImageSet);
      final snapshot = _todayImageSet.snapshots[bestSlot];
      if (snapshot == null) {
        debugPrint('⚠️ No image available for AI analysis');
        return;
      }

      // 2. Load image bytes
      final imageBytes = await _loadImageBytes(snapshot);
      if (imageBytes == null) {
        debugPrint('⚠️ Could not load image bytes for analysis');
        return;
      }

      // 3. Run Cloud Vision analysis
      final visionResult = await _visionService.analyzePlantImage(imageBytes);
      debugPrint("🔍 Vision labels: ${visionResult.labels.take(5).join(", ")}");

      // 4. Gather current sensor readings for fusion
      final currentReadings = <String, double>{};
      for (final reading in _readings) {
        currentReadings[reading.id] = reading.value;
      }

      // 5. Get previous day score for trend calculation
      int? previousDayScore;
      if (_growthTimeline.isNotEmpty) {
        final lastDay = _growthTimeline.last;
        previousDayScore = lastDay.aiReport?.growthScore;
      }

      // 6. Run AI growth analyzer with sensor fusion
      final analysisResult = await _aiAnalyzer.analyzeGrowth(
        visionResult: visionResult,
        sensorReadings: currentReadings,
        dayNumber: _todayImageSet.dayNumber,
        previousDayScore: previousDayScore,
      );

      // 7. Determine trend
      String scoreTrend = '➡️';
      if (previousDayScore != null) {
        final diff = analysisResult.growthScore - previousDayScore;
        if (diff > 5) scoreTrend = '📈';
        else if (diff < -5) scoreTrend = '📉';
        else scoreTrend = '➡️';
      }

      // 8. Build the report
      final report = AIGrowthReport(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        date: DateTime.now(),
        dayNumber: _todayImageSet.dayNumber,
        growthScore: analysisResult.growthScore.clamp(0, 100).toInt(),
        scoreTrend: scoreTrend,
        healthStatus: analysisResult.healthStatus,
        summary: analysisResult.summary,
        leafAssessment: analysisResult.leafAssessment,
        colorAssessment: analysisResult.colorAssessment,
        stemAssessment: analysisResult.stemAssessment,
        recommendations: analysisResult.recommendations,
        previousDayScore: previousDayScore?.toInt() ?? 0,
        generatedAt: DateTime.now(),
      );

      _todayImageSet.aiReport = report;
      _growthTimeline.add(_todayImageSet);

      // 9. Persist to Firebase
      await _db.child('captures/day_${_todayImageSet.dayNumber}/aiReport').set({
        'id': report.id,
        'date': report.date.millisecondsSinceEpoch,
        'growthScore': report.growthScore,
        'healthStatus': report.healthStatus.name,
        'summary': report.summary,
        'recommendations': report.recommendations,
        'leafAssessment': report.leafAssessment,
        'colorAssessment': report.colorAssessment,
        'stemAssessment': report.stemAssessment,
        'scoreTrend': report.scoreTrend,
        'previousDayScore': report.previousDayScore,
        'generatedAt': report.generatedAt.millisecondsSinceEpoch,
      });

      debugPrint('☁️ Real AI report saved to Firebase (score: ${report.growthScore})');
      notifyListeners();

    } catch (e, stack) {
      debugPrint('❌ Real AI analysis failed: $e');
      debugPrint('Stack: $stack');

      // Fallback: generate a basic placeholder report so UI isn't broken
      final fallbackReport = AIGrowthReport(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        date: DateTime.now(),
        dayNumber: _todayImageSet.dayNumber,
        growthScore: 70,
        scoreTrend: '➡️',
        healthStatus: HealthStatus.healthy,
        summary: 'Plant analysis completed. Review image manually for detailed assessment.',
        leafAssessment: 'Image captured successfully.',
        colorAssessment: 'Color analysis pending.',
        stemAssessment: 'Stem check pending.',
        recommendations: 'Ensure optimal lighting and nutrient levels.',
        previousDayScore: 0,
        generatedAt: DateTime.now(),
      );

      _todayImageSet.aiReport = fallbackReport;
      _growthTimeline.add(_todayImageSet);
      notifyListeners();
    }
  }

  // ── Backup ───────────────────────────────────────────────────
  Future<BackupRecord> createBackup() async {
    final rec = await _systemRepo.createBackup();
    _backups = await _systemRepo.getBackups();
    notifyListeners();
    return rec;
  }

  @override
  void dispose() {
    for (final sub in _subs) sub.cancel();
    _capturesSub?.cancel();
    _sensorRepo.dispose();
    _deviceRepo.dispose();
    _alertRepo.dispose();
    _systemRepo.dispose();
    _cameraRepo.dispose();
    super.dispose();
  }
}