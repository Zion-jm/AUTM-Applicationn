import 'dart:math';
import '../domain/models/sensor_data.dart';

class MockDataService {
  static final MockDataService _instance = MockDataService._internal();
  factory MockDataService() => _instance;
  MockDataService._internal() { _initGrowthTimeline(); }

  final _random = Random();
  final _sensorHistory = <String, List<SensorDataPoint>>{};

  // ── Live sensor values ──────────────────────────────────────
  double _temp     = 27.5;
  double _humidity = 72.0;
  double _light    = 11500.0;
  double _moisture = 74.0;
  double _ph       = 6.2;
  double _ec       = 1.8;

  // ── Alert log ───────────────────────────────────────────────
  final List<AlertRecord> _alerts = [];
  int _alertIdCounter = 0;

  // ── Growth timeline ─────────────────────────────────────────
  final List<DailyImageSet> _growthTimeline = [];
  int _snapshotIdCounter = 0;

  // ── Backup records ──────────────────────────────────────────
  final List<BackupRecord> _backups = [];
  int _backupIdCounter = 0;

  // ─────────────────────────────────────────────────────────────
  // SENSORS
  // ─────────────────────────────────────────────────────────────
  List<SensorReading> get currentReadings => [
        _reading('temperature', 'Air Temperature',    _temp,     '°C',    20, 40, 24, 28, 'thermostat'),
        _reading('humidity',    'Relative Humidity',  _humidity, '%',     40, 100, 50, 75, 'water_drop'),
        _reading('light',       'Light Intensity',    _light,    'lux',   0, 25000, 10000, 20000, 'wb_sunny'),
        _reading('moisture',    'Substrate Moisture', _moisture, '%',     0, 100, 60, 90, 'grass'),
        _reading('ph',          'Nutrient pH',        _ph,       'pH',    4.0, 9.0, 5.5, 7.0, 'science'),
        _reading('ec',          'Nutrient EC',        _ec,       'mS/cm', 0.5, 4.0, 1.2, 2.5, 'bolt'),
      ];

  SensorReading _reading(String id, String label, double value, String unit,
      double min, double max, double wLow, double wHigh, String icon) {
    return SensorReading(
      id: id, label: label, value: double.parse(value.toStringAsFixed(2)),
      unit: unit, min: min, max: max,
      warningLow: wLow, warningHigh: wHigh,
      icon: icon, timestamp: DateTime.now(),
    );
  }

  void tick() {
    _temp     = _clamp(_temp     + _drift(0.3),  24.0, 34.0);
    _humidity = _clamp(_humidity + _drift(0.8),  55.0, 90.0);
    _light    = _clamp(_light    + _drift(300),  8000, 18000);
    _moisture = _clamp(_moisture + _drift(0.4),  55.0, 95.0);
    _ph       = _clamp(_ph       + _drift(0.05), 5.0,  7.5);
    _ec       = _clamp(_ec       + _drift(0.05), 1.0,  3.0);

    final now = DateTime.now();
    for (final r in currentReadings) {
      _sensorHistory.putIfAbsent(r.id, () => [])
          .add(SensorDataPoint(time: now, value: r.value));
      final hist = _sensorHistory[r.id]!;
      if (hist.length > 288) hist.removeAt(0);

      // Auto-generate alerts when status changes to alert
      if (r.status == SensorStatus.alert) {
        final existing = _alerts.where(
          (a) => a.sensorId == r.id && !a.isResolved).toList();
        if (existing.isEmpty) {
          _alerts.add(AlertRecord(
            id: 'ALT${++_alertIdCounter}',
            sensorId: r.id,
            sensorLabel: r.label,
            value: r.value,
            unit: r.unit,
            alertType: SensorStatus.alert,
            createdAt: now,
          ));
        }
      } else {
        // Auto-resolve
        for (final a in _alerts.where(
            (a) => a.sensorId == r.id && !a.isResolved)) {
          a.isResolved = true;
          a.resolvedAt = now;
        }
      }
    }
  }

  SensorHistory historyFor(String sensorId) {
    final hist = _sensorHistory[sensorId] ?? [];
    if (hist.isEmpty) return _syntheticHistory(sensorId, 48);
    return SensorHistory(sensorId: sensorId, points: hist);
  }

  SensorHistory _syntheticHistory(String sensorId, int count) {
    final now = DateTime.now();
    final points = <SensorDataPoint>[];
    double base, variance;
    switch (sensorId) {
      case 'temperature': base = 27.0;  variance = 2.0;    break;
      case 'humidity':    base = 70.0;  variance = 8.0;    break;
      case 'light':       base = 12000; variance = 2000;   break;
      case 'moisture':    base = 72.0;  variance = 10.0;   break;
      case 'ph':          base = 6.2;   variance = 0.4;    break;
      case 'ec':          base = 1.8;   variance = 0.3;    break;
      default:            base = 50.0;  variance = 5.0;
    }
    double val = base;
    for (int i = count; i >= 0; i--) {
      val = (val + (_random.nextDouble() - 0.5) * variance * 0.4)
          .clamp(base - variance, base + variance);
      points.add(SensorDataPoint(
        time: now.subtract(Duration(minutes: i * 5)),
        value: double.parse(val.toStringAsFixed(2)),
      ));
    }
    return SensorHistory(sensorId: sensorId, points: points);
  }

  // ─────────────────────────────────────────────────────────────
  // DEVICES
  // ─────────────────────────────────────────────────────────────
  List<DeviceState> _deviceStates = [
    DeviceState(id: 'exhaust_fan',       label: 'Exhaust Fan',       icon: 'air',        isOn: false, status: DeviceStatus.auto, triggerReason: 'Auto: temp threshold'),
    DeviceState(id: 'circulation_fan_1', label: 'Circulation Fan 1', icon: 'cyclone',    isOn: true,  status: DeviceStatus.auto, triggerReason: 'Auto: humidity threshold'),
    DeviceState(id: 'circulation_fan_2', label: 'Circulation Fan 2', icon: 'cyclone',    isOn: true,  status: DeviceStatus.auto, triggerReason: 'Auto: humidity threshold'),
    DeviceState(id: 'pump',              label: 'Submersible Pump',  icon: 'water',      isOn: false, status: DeviceStatus.auto,
      lastTriggered: DateTime.now().subtract(const Duration(minutes: 23)),
      triggerReason: 'Auto: moisture cycle'),
    DeviceState(id: 'grow_light',        label: 'LED Grow Light',    icon: 'light_mode', isOn: true,  status: DeviceStatus.auto, triggerReason: 'Auto: light threshold'),
  ];

  List<DeviceState> get deviceStates => List.unmodifiable(_deviceStates);

  void setDeviceStatus(String deviceId, DeviceStatus status, bool isOn) {
    _deviceStates = _deviceStates.map((d) {
      if (d.id != deviceId) return d;
      return d.copyWith(
        status: status, isOn: isOn,
        lastTriggered: DateTime.now(),
        triggerReason: status == DeviceStatus.auto ? 'Auto: threshold' : 'Manual override',
      );
    }).toList();
  }

  //List<AutomationRule> get automationRules => [
  //      AutomationRule(sensorId: 'temperature', deviceId: 'exhaust_fan',       triggerLow: 0,     triggerHigh: 28.0,  actionDescription: 'Turn ON exhaust fan when temp > 28°C, OFF when ≤ 26°C'),
  //      AutomationRule(sensorId: 'humidity',    deviceId: 'circulation_fan_1', triggerLow: 0,     triggerHigh: 75.0,  actionDescription: 'Turn ON circulation fans when RH > 75%, OFF when ≤ 70%'),
  //      AutomationRule(sensorId: 'moisture',    deviceId: 'pump',              triggerLow: 60.0,  triggerHigh: 100,   actionDescription: 'Run pump for 2 min when moisture < 60%'),
  //      AutomationRule(sensorId: 'light',       deviceId: 'grow_light',        triggerLow: 10000, triggerHigh: 99999, actionDescription: 'Turn ON grow light when lux < 10,000 (6AM–6PM)'),
  //    ];

  // ─────────────────────────────────────────────────────────────
  // ALERTS
  // ─────────────────────────────────────────────────────────────
  List<AlertRecord> get allAlerts => List.unmodifiable(_alerts.reversed.toList());
  List<AlertRecord> get activeAlerts => _alerts.where((a) => !a.isResolved).toList();

  // ─────────────────────────────────────────────────────────────
  // CAMERA / AI GROWTH TIMELINE
  // ─────────────────────────────────────────────────────────────
  void _initGrowthTimeline() {
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

      final snaps = <CaptureSlot, PlantSnapshot>{};
      for (final slot in CaptureSlot.values) {
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

      _growthTimeline.add(DailyImageSet(
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
    _growthTimeline.add(DailyImageSet(
      date: now, dayNumber: 8,
      snapshots: todaySnaps, aiReport: null,
    ));
  }

  DateTime _slotTime(DateTime date, CaptureSlot slot) {
    switch (slot) {
      case CaptureSlot.morning:   return DateTime(date.year, date.month, date.day, 6, 0);
      case CaptureSlot.afternoon: return DateTime(date.year, date.month, date.day, 14, 0);
      case CaptureSlot.evening:   return DateTime(date.year, date.month, date.day, 22, 0);
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

  List<DailyImageSet> get growthTimeline => List.unmodifiable(_growthTimeline.reversed.toList());

  DailyImageSet get todayImageSet => _growthTimeline.last;

  PlantSnapshot addManualCapture() {
    final snap = PlantSnapshot(
      id: 'SNAP${++_snapshotIdCounter}',
      slot: CaptureSlot.morning,
      capturedAt: DateTime.now(),
      isManual: true,
      dayNumber: todayImageSet.dayNumber,
    );
    return snap;
  }

  // ─────────────────────────────────────────────────────────────
  // BACKUP
  // ─────────────────────────────────────────────────────────────
  List<BackupRecord> get backups => List.unmodifiable(_backups.reversed.toList());

  BackupRecord createBackup() {
    final record = BackupRecord(
      id: 'BKP${++_backupIdCounter}',
      createdAt: DateTime.now(),
      sensorReadingCount: _sensorHistory.values.fold(0, (sum, list) => sum + list.length),
      alertCount: _alerts.length,
      snapshotCount: _snapshotIdCounter,
      status: 'success',
    );
    _backups.add(record);
    return record;
  }

  // ─────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────
  double _drift(double scale) => (_random.nextDouble() - 0.5) * scale;
  double _clamp(double v, double lo, double hi) => v.clamp(lo, hi);
}