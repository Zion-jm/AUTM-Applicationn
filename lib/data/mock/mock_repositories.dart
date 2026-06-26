// ═══════════════════════════════════════════════════════════════
// MOCK REPOSITORIES
// ═══════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math';
import '../../domain/models/models.dart';
import '../../domain/repositories/repositories.dart';

// ── Shared tick source ────────────────────────────────────────
class _MockClock {
  static final _MockClock _instance = _MockClock._();
  factory _MockClock() => _instance;
  _MockClock._();
  final _controller = StreamController<DateTime>.broadcast();
  Timer? _timer;
  int _subscriberCount = 0;

  Stream<DateTime> get ticks => _controller.stream;

  void addSubscriber() {
    _subscriberCount++;
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_controller.isClosed) _controller.add(DateTime.now());
    });
  }

  void removeSubscriber() {
    _subscriberCount--;
    if (_subscriberCount <= 0) {
      _timer?.cancel();
      _timer = null;
      _subscriberCount = 0;
    }
  }
}

// ── MOCK SENSOR REPOSITORY ─────────────────────────────────────
class MockSensorRepository implements SensorRepository {
  final _random = Random();
  final _clock  = _MockClock();
  final _historyMap = <String, List<SensorDataPoint>>{};

  double _temp     = 27.5;
  double _humidity = 72.0;
  double _light    = 11500.0;
  double _moisture = 74.0;
  double _ph       = 6.2;
  double _ec       = 1.8;

  late final Stream<List<SensorReading>> _stream;

  MockSensorRepository() {
    _clock.addSubscriber();
    _stream = _clock.ticks.map((_) {
      _tick();
      return _buildReadings();
    }).asBroadcastStream();
  }

  @override
  Stream<List<SensorReading>> get sensorStream => _stream;

  @override
  SensorHistory historyFor(String sensorId) {
    final hist = _historyMap[sensorId];
    if (hist != null && hist.isNotEmpty) {
      return SensorHistory(sensorId: sensorId, points: List.unmodifiable(hist));
    }
    return _syntheticHistory(sensorId, 48);
  }

  @override
  Future<SensorHistory> fetchHistory(String sensorId, {Duration duration = const Duration(hours: 6)}) async {
    return historyFor(sensorId);
  }

  void _tick() {
    _temp     = _clamp(_temp     + _drift(0.3),  24.0, 34.0);
    _humidity = _clamp(_humidity + _drift(0.8),  55.0, 90.0);
    _light    = _clamp(_light    + _drift(300),  8000, 18000);
    _moisture = _clamp(_moisture + _drift(0.4),  55.0, 95.0);
    _ph       = _clamp(_ph       + _drift(0.05), 5.0,  7.5);
    _ec       = _clamp(_ec       + _drift(0.05), 1.0,  3.0);

    final now = DateTime.now();
    for (final r in _buildReadings()) {
      final list = _historyMap.putIfAbsent(r.id, () => []);
      list.add(SensorDataPoint(time: now, value: r.value));
      if (list.length > 288) list.removeAt(0);
    }
  }

  List<SensorReading> _buildReadings() => [
    _r('temperature', 'Air Temperature',    _temp,     '°C',    20, 40, 24, 28, 'thermostat'),
    _r('humidity',    'Relative Humidity',  _humidity, '%',     40, 100, 50, 75, 'water_drop'),
    _r('light',       'Light Intensity',    _light,    'lux',   0, 25000, 10000, 20000, 'wb_sunny'),
    _r('moisture',    'Substrate Moisture', _moisture, '%',     0, 100, 60, 90, 'grass'),
    _r('ph',          'Nutrient pH',        _ph,       'pH',    4.0, 9.0, 5.5, 7.0, 'science'),
    _r('ec',          'Nutrient EC',        _ec,       'mS/cm', 0.5, 4.0, 1.2, 2.5, 'bolt'),
  ];

  SensorReading _r(String id, String label, double value, String unit,
      double min, double max, double wLow, double wHigh, String icon) {
    return SensorReading(
      id: id, label: label,
      value: double.parse(value.toStringAsFixed(2)),
      unit: unit, min: min, max: max,
      warningLow: wLow, warningHigh: wHigh,
      icon: icon, timestamp: DateTime.now(),
    );
  }

  SensorHistory _syntheticHistory(String id, int count) {
    final now = DateTime.now();
    double base, variance;
    switch (id) {
      case 'temperature': base = 27.0;  variance = 2.0;    break;
      case 'humidity':    base = 70.0;  variance = 8.0;    break;
      case 'light':       base = 12000; variance = 2000;   break;
      case 'moisture':    base = 72.0;  variance = 10.0;   break;
      case 'ph':          base = 6.2;   variance = 0.4;    break;
      case 'ec':          base = 1.8;   variance = 0.3;    break;
      default:            base = 50.0;  variance = 5.0;
    }
    double val = base;
    final pts = <SensorDataPoint>[];
    for (int i = count; i >= 0; i--) {
      val = (val + (_random.nextDouble() - 0.5) * variance * 0.4)
          .clamp(base - variance, base + variance);
      pts.add(SensorDataPoint(
        time: now.subtract(Duration(minutes: i * 5)),
        value: double.parse(val.toStringAsFixed(2)),
      ));
    }
    return SensorHistory(sensorId: id, points: pts);
  }

  double _drift(double scale) => (_random.nextDouble() - 0.5) * scale;
  double _clamp(double v, double lo, double hi) => v.clamp(lo, hi);

  @override
  void dispose() {
    _clock.removeSubscriber();
  }
}

// ── MOCK DEVICE REPOSITORY ─────────────────────────────────────
class MockDeviceRepository implements DeviceRepository {
  final _deviceController = StreamController<List<DeviceState>>.broadcast();

  List<DeviceState> _devices = [
    const DeviceState(id: 'exhaust_fan',       label: 'Exhaust Fan',       icon: 'air',        isOn: false, status: DeviceStatus.auto,     triggerReason: 'Auto: temp threshold'),
    const DeviceState(id: 'circulation_fan_1', label: 'Circulation Fan 1', icon: 'cyclone',    isOn: true,  status: DeviceStatus.auto,     triggerReason: 'Auto: humidity threshold'),
    const DeviceState(id: 'circulation_fan_2', label: 'Circulation Fan 2', icon: 'cyclone',    isOn: true,  status: DeviceStatus.auto,     triggerReason: 'Auto: humidity threshold'),
    const DeviceState(id: 'pump',              label: 'Submersible Pump',  icon: 'water',      isOn: false, status: DeviceStatus.auto,     triggerReason: 'Auto: moisture cycle'),
    const DeviceState(id: 'grow_light',        label: 'LED Grow Light',    icon: 'light_mode', isOn: true,  status: DeviceStatus.auto,     triggerReason: 'Auto: light threshold'),
  ];

  @override
  Stream<List<DeviceState>> get deviceStream => _deviceController.stream;

  @override
  List<DeviceState> get currentDevices => List.unmodifiable(_devices);

  @override
  void setDeviceStatus(String deviceId, DeviceStatus status, bool isOn) {
    _devices = _devices.map((d) {
      if (d.id != deviceId) return d;
      return d.copyWith(
        isOn:          isOn,
        status:        status,
        lastTriggered: DateTime.now(),
        triggerReason: status == DeviceStatus.auto
            ? 'Auto: threshold'
            : 'Manual override',
      );
    }).toList();
    _deviceController.add(List.unmodifiable(_devices));
  }

  @override
  List<AutomationRule> get automationRules => const [
    AutomationRule(
      id: 'rule_1',
      sensorId: 'temperature',
      deviceId: 'exhaust_fan',
      triggerLow: 0,
      triggerHigh: 28.0,
      actionDescription: 'Turn ON exhaust fan when temp > 28°C, OFF when ≤ 26°C',
    ),
    AutomationRule(
      id: 'rule_2',
      sensorId: 'humidity',
      deviceId: 'circulation_fan_1',
      triggerLow: 0,
      triggerHigh: 75.0,
      actionDescription: 'Turn ON circulation fans when RH > 75%, OFF when ≤ 70%',
    ),
    AutomationRule(
      id: 'rule_3',
      sensorId: 'moisture',
      deviceId: 'pump',
      triggerLow: 60.0,
      triggerHigh: 100,
      actionDescription: 'Run pump for 2 min when moisture < 60%',
    ),
    AutomationRule(
      id: 'rule_4',
      sensorId: 'light',
      deviceId: 'grow_light',
      triggerLow: 10000,
      triggerHigh: 99999,
      actionDescription: 'Turn ON grow light when lux < 10,000 (6AM–6PM)',
    ),
  ];

  @override
  void dispose() => _deviceController.close();
}

// ── MOCK ALERT REPOSITORY ──────────────────────────────────────
class MockAlertRepository implements AlertRepository {
  final _controller    = StreamController<List<AlertRecord>>.broadcast();
  final List<AlertRecord> _alerts = [];
  int _idCounter = 0;
  Set<String> _activeAlertSensorIds = {};

  MockAlertRepository(Stream<List<SensorReading>> sensorStream) {
    sensorStream.listen((readings) {
      bool changed = false;
      final now = DateTime.now();

      for (final r in readings) {
        if (r.status == SensorStatus.alert) {
          if (!_activeAlertSensorIds.contains(r.id)) {
            _activeAlertSensorIds.add(r.id);
            _alerts.add(AlertRecord(
              id:          'ALT${++_idCounter}',
              sensorId:    r.id,
              sensorLabel: r.label,
              value:       r.value,
              unit:        r.unit,
              alertType:   SensorStatus.alert,
              createdAt:   now,
            ));
            changed = true;
          }
        } else {
          if (_activeAlertSensorIds.contains(r.id)) {
            _activeAlertSensorIds.remove(r.id);
            for (int i = 0; i < _alerts.length; i++) {
              if (_alerts[i].sensorId == r.id && !_alerts[i].isResolved) {
                _alerts[i] = _alerts[i].copyWith(
                    isResolved: true, resolvedAt: now);
                changed = true;
              }
            }
          }
        }
      }

      if (changed) _controller.add(List.unmodifiable(_alerts.reversed.toList()));
    });
  }

  @override
  Stream<List<AlertRecord>> get alertStream => _controller.stream;

  @override
  Future<void> resolveAlert(String alertId) async {
    for (int i = 0; i < _alerts.length; i++) {
      if (_alerts[i].id == alertId) {
        _alerts[i] = _alerts[i].copyWith(
            isResolved: true, resolvedAt: DateTime.now());
        break;
      }
    }
    _controller.add(List.unmodifiable(_alerts.reversed.toList()));
  }

  @override
  void dispose() => _controller.close();
}

// ── MOCK SYSTEM REPOSITORY ─────────────────────────────────────
class MockSystemRepository implements SystemRepository {
  final _controller = StreamController<SystemStatus>.broadcast();
  final _clock      = _MockClock();
  late final StreamSubscription<DateTime> _sub;
  final _backups    = <BackupRecord>[];
  int _backupId     = 0;

  MockSystemRepository() {
    _clock.addSubscriber();
    _controller.add(_connected());
    _sub = _clock.ticks.listen((_) => _controller.add(_connected()));
  }

  SystemStatus _connected() => SystemStatus(
    isConnected:     true,
    lastSeen:        DateTime.now(),
    firmwareVersion: '1.0.0-mock',
    isDataFresh:     true,
  );

  @override
  Stream<SystemStatus> get statusStream => _controller.stream;

  @override
  Future<BackupRecord> createBackup() async {
    await Future.delayed(const Duration(seconds: 2));
    final rec = BackupRecord(
      id:                 'BKP${++_backupId}',
      createdAt:          DateTime.now(),
      sensorReadingCount: 1440,
      alertCount:         12,
      snapshotCount:      24,
      status:             'success',
    );
    _backups.add(rec);
    return rec;
  }

  @override
  Future<List<BackupRecord>> getBackups() async =>
      List.unmodifiable(_backups.reversed.toList());

  @override
  void dispose() {
    _sub.cancel();
    _clock.removeSubscriber();
    _controller.close();
  }
}

// ── MOCK CAMERA REPOSITORY ─────────────────────────────────────
class MockCameraRepository implements CameraRepository {
  final _todayController = StreamController<DailyImageSet>.broadcast();
  final List<PlantSnapshot> _manualSnapshots = [];
  int _snapshotIdCounter = 0;

  late final List<DailyImageSet> _growthTimeline;

  MockCameraRepository() {
    _growthTimeline = _initGrowthTimeline();
  }

  List<DailyImageSet> _initGrowthTimeline() {
    final timeline = <DailyImageSet>[];
    final now = DateTime.now();
    final scores = [62, 67, 71, 74, 78, 82, 85];
    final statuses = [
      HealthStatus.fair, HealthStatus.fair, HealthStatus.healthy,
      HealthStatus.healthy, HealthStatus.healthy, HealthStatus.healthy, HealthStatus.healthy
    ];

    for (int day = 7; day >= 1; day--) {
      final date = now.subtract(Duration(days: day));
      final dayNum = 8 - day;
      final score = scores[dayNum - 1];
      final prevScore = dayNum > 1 ? scores[dayNum - 2] : null;
      final trend = prevScore == null ? '→'
          : score > prevScore ? '↑'
          : score < prevScore ? '↓' : '→';

      // Only create snapshots for SCHEDULED slots (not manual)
      final snaps = <CaptureSlot, PlantSnapshot>{};
      for (final slot in [CaptureSlot.morning, CaptureSlot.afternoon, CaptureSlot.evening]) {
        snaps[slot] = PlantSnapshot(
          id: 'SNAP${++_snapshotIdCounter}',
          slot: slot,
          capturedAt: _slotTime(date, slot),
          isManual: false,
          dayNumber: dayNum,
        );
      }

      final report = AIGrowthReport(
        id: 'RPT$dayNum',
        date: date,
        dayNumber: dayNum,
        growthScore: score,
        healthStatus: statuses[dayNum - 1],
        summary: _summaryFor(dayNum, score),
        recommendations: _recFor(dayNum),
        leafAssessment: 'Leaves appear ${score > 75 ? "vibrant and well-expanded" : "moderate in size with visible growth"}.',
        colorAssessment: 'Color is ${score > 75 ? "deep green indicating healthy chlorophyll" : "light green, acceptable for this stage"}.',
        stemAssessment: 'Stem is ${score > 75 ? "upright and sturdy" : "developing normally"}.',
        scoreTrend: trend,
        previousDayScore: prevScore,
        generatedAt: _slotTime(date, CaptureSlot.evening).add(const Duration(minutes: 5)),
      );

      timeline.add(DailyImageSet(
        date: date, dayNumber: dayNum,
        snapshots: snaps, aiReport: report,
      ));
    }

    // Today: only morning captured so far
    final todaySnaps = <CaptureSlot, PlantSnapshot>{
      CaptureSlot.morning: PlantSnapshot(
        id: 'SNAP${++_snapshotIdCounter}',
        slot: CaptureSlot.morning,
        capturedAt: _slotTime(now, CaptureSlot.morning),
        isManual: false,
        dayNumber: 8,
      ),
    };
    timeline.add(DailyImageSet(
      date: now, dayNumber: 8,
      snapshots: todaySnaps, aiReport: null,
    ));

    return timeline;
  }

  DateTime _slotTime(DateTime date, CaptureSlot slot) {
    switch (slot) {
      case CaptureSlot.morning:   return DateTime(date.year, date.month, date.day, 6, 0);
      case CaptureSlot.afternoon: return DateTime(date.year, date.month, date.day, 14, 0);
      case CaptureSlot.evening:   return DateTime(date.year, date.month, date.day, 22, 0);
      case CaptureSlot.manual:    return DateTime.now(); // Manual captures use current time
    }
  }

  String _summaryFor(int day, int score) {
    if (score >= 80) return 'Plant is thriving. Canopy coverage has increased significantly and leaf coloration is optimal. The greenhouse environment is maintaining excellent conditions for continued growth.';
    if (score >= 70) return 'Plant is showing healthy growth patterns. Minor variations in light distribution observed but within acceptable range. Overall development is on track.';
    return 'Early-stage growth detected. Leaves are forming and root system appears to be establishing. Conditions are suitable for continued development.';
  }

  String _recFor(int day) {
    if (day <= 2) return 'Ensure consistent watering schedule. Monitor pH closely during root establishment phase.';
    if (day <= 5) return 'Maintain current nutrient levels. Consider adjusting grow light duration by 30 minutes to optimize photosynthesis.';
    return 'Growth is progressing well. Continue current automation rules. Check EC levels weekly.';
  }

  @override
  Stream<DailyImageSet> get todayStream => _todayController.stream;

  @override
  DailyImageSet get todayImageSet => _growthTimeline.last;

  @override
  List<DailyImageSet> get growthTimeline => List.unmodifiable(_growthTimeline.reversed.toList());

  @override
  List<PlantSnapshot> get manualSnapshots => List.unmodifiable(_manualSnapshots);

  @override
  String nextCaptureLabel() {
    final hour = DateTime.now().hour;
    if (hour < 6)  return 'Morning capture at 6:00 AM';
    if (hour < 14) return 'Afternoon capture at 2:00 PM';
    if (hour < 22) return 'Evening capture at 10:00 PM';
    return 'Morning capture at 6:00 AM tomorrow';
  }

  @override
  PlantSnapshot triggerManualCapture() {
    final snap = PlantSnapshot(
      id: 'SNAP${++_snapshotIdCounter}',
      slot: CaptureSlot.manual,  // ← FIXED: was CaptureSlot.morning
      capturedAt: DateTime.now(),
      isManual: true,
      dayNumber: todayImageSet.dayNumber,
    );
    _manualSnapshots.add(snap);
    return snap;
  }

  @override
  void dispose() => _todayController.close();
}

// ── MOCK AUTH REPOSITORY ───────────────────────────────────────
class MockAuthRepository implements AuthRepository {
  final _mockEmail = 'admin@autm.ph';
  final _mockPass  = 'tomato123';

  @override
  Future<bool> signIn(String email, String password) async {
    await Future.delayed(const Duration(milliseconds: 1400));
    if (email.trim() == _mockEmail && password == _mockPass) {
      return true;
    }
    throw Exception('Incorrect email or password. Please try again.');
  }

  @override
  Future<bool> signUp(String email, String password) async {
    // Mock always succeeds
    return true;
  }

  @override
  void dispose() {}
}