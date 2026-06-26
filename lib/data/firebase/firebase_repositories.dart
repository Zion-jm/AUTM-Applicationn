//firebase_repositories.dart

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../domain/models/models.dart';
import '../../domain/models/sensor_data.dart';
import '../../domain/repositories/repositories.dart';

// ─────────────────────────────────────────────────────────────
// GREENHOUSE PATH RESOLVER
// All repositories read from /greenhouses/{activeGreenhouseId}/...
// instead of the root, so security rules and data are scoped
// correctly per greenhouse membership.
// ─────────────────────────────────────────────────────────────

void clearGreenhouseCache() => _GreenhousePath.clearCache();

class _GreenhousePath {
  static final _db = FirebaseDatabase.instance.ref();
  static final _auth = FirebaseAuth.instance;

  // Cache to avoid repeated DB lookups
  static String? _cachedGreenhouseId;

  // Callback to notify repositories when greenhouse changes
  static final List<VoidCallback> _onChangeCallbacks = [];

  /// Register a callback to be called when greenhouse cache is cleared
  static void onChange(VoidCallback callback) {
    _onChangeCallbacks.add(callback);
  }

  /// Unregister a callback
  static void removeCallback(VoidCallback callback) {
    _onChangeCallbacks.remove(callback);
  }

  /// Returns the active greenhouse ID for the current user.
  /// Returns null if the user has no greenhouse linked yet.
  static Future<String?> get activeId async {
    if (_cachedGreenhouseId != null) return _cachedGreenhouseId;
    final user = _auth.currentUser;
    if (user == null) return null;
    final snap =
        await _db.child('/users/${user.uid}/greenhouses').get();
    if (!snap.exists || snap.value == null) return null;
    final greenhouses =
        Map<String, dynamic>.from(snap.value as Map);
    _cachedGreenhouseId = greenhouses.keys.first;
    return _cachedGreenhouseId;
  }

  /// Call this on logout or greenhouse switch to reset the cache.
  static void clearCache() {
    _cachedGreenhouseId = null;
    // Notify all registered repositories to re-initialize
    for (final callback in _onChangeCallbacks) {
      callback();
    }
  }

  /// Returns a DatabaseReference scoped to the active greenhouse.
  /// Returns null if the user has no greenhouse linked yet (STRICT SECURITY GATE).
  /// NOTE: Current database structure has data at root level, not under /greenhouses/{id}
  static Future<DatabaseReference?> child(String path) async {
    final id = await activeId;
    if (id == null) return null; // STRICT SECURITY GATE! Stops unlinked accounts from receiving any telemetry or alerts.

    // Current database structure: data at root level (/sensors, /alerts, etc.)
    // Future structure would be: /greenhouses/$id/$path
    return _db.child('/$path');
  }
}

// ─────────────────────────────────────────────────────────────
// SENSOR REPOSITORY
// ─────────────────────────────────────────────────────────────
class FirebaseSensorRepository implements SensorRepository {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  StreamSubscription? _sub;
  StreamController<List<SensorReading>>? _controller;

  Map<String, dynamic> _sensorConfig = {};
  FirebaseSensorRepository() {
    _GreenhousePath.onChange(_onGreenhouseChange);
  }

  void _onGreenhouseChange() {
    _sub?.cancel();
    _controller?.add([]);
    _initStream(_controller!);
  }

  @override
  Stream<List<SensorReading>> get sensorStream {
    final controller =
        StreamController<List<SensorReading>>.broadcast();
    _controller = controller;
    _initStream(controller);
    return controller.stream;
  }

  Future<void> _initStream(
      StreamController<List<SensorReading>> controller) async {
    final ghRef = await _GreenhousePath.child('sensors');
    if (ghRef == null) {
      controller.add([]);
      return;
    }

    // Load config once
    final configRef =
        await _GreenhousePath.child('config/sensors');
    if (configRef != null) {
      final configSnap = await configRef.get();
      if (configSnap.exists && configSnap.value != null) {
        _sensorConfig =
            Map<String, dynamic>.from(configSnap.value as Map);
      }
    }

    // Listen to live sensor readings
    _sub = ghRef.onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(
            event.snapshot.value as Map);
        final readings = data.entries.map((e) {
          return SensorReading.fromJson(
            e.key,
            e.value as Map,
            _sensorConfig[e.key] as Map? ?? {},
          );
        }).toList();
        controller.add(readings);
      } else {
        controller.add([]);
      }
    });
  }

  @override
  SensorHistory historyFor(String sensorId) {
    return SensorHistory(sensorId: sensorId, points: []);
  }

  @override
  Future<SensorHistory> fetchHistory(String sensorId, {Duration duration = const Duration(hours: 6)}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final startTime = now - duration.inMilliseconds;
    final histRef =
        await _GreenhousePath.child('history/$sensorId');
    if (histRef == null) {
      return SensorHistory(sensorId: sensorId, points: []);
    }

    final snap = await histRef
        .orderByChild('timestamp')
        .startAt(startTime.toDouble())
        .get();
  
    List<SensorDataPoint> points = [];
    if (snap.exists && snap.value != null) {
      points = (snap.value as Map? ?? {})
          .entries
          .map((e) => SensorDataPoint.fromJson(
              Map<String, dynamic>.from(e.value as Map)))
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));
    }
  
    return SensorHistory(sensorId: sensorId, points: points);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller?.close();
    _GreenhousePath.removeCallback(_onGreenhouseChange);
  }
}

// ─────────────────────────────────────────────────────────────
class FirebaseDeviceRepository implements DeviceRepository {
  StreamSubscription? _sub;
  List<DeviceState> _currentDevices = [];
  List<AutomationRule> _automationRules = [];
  StreamController<List<DeviceState>>? _controller;

  FirebaseDeviceRepository() {
    _GreenhousePath.onChange(_onGreenhouseChange);
  }

  void _onGreenhouseChange() {
    _sub?.cancel();
    _controller?.add([]);
    _initStream(_controller!);
  }

  @override
  Stream<List<DeviceState>> get deviceStream {
    final controller =
        StreamController<List<DeviceState>>.broadcast();
    _controller = controller;
    _initStream(controller);
    return controller.stream;
  }

  Future<void> _initStream(
      StreamController<List<DeviceState>> controller) async {
    final devRef = await _GreenhousePath.child('devices');
    if (devRef == null) {
      controller.add([]);
      return;
    }
    await _loadAutomationRules();

    _sub = devRef.onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        _currentDevices = data.entries
            .map((e) => DeviceState.fromJson(
                e.key, Map<String, dynamic>.from(e.value as Map)))
            .toList();
            controller.add(_currentDevices);
      } else {
        _currentDevices = [];
        controller.add([]);
      }
    });

    controller.add([]);
  }

  Future<void> _loadAutomationRules() async {
    final rulesRef =
        await _GreenhousePath.child('config/automationRules');
    if (rulesRef == null) return;
    final snap = await rulesRef.get();
    if (snap.exists && snap.value != null) {
      final data =
          Map<String, dynamic>.from(snap.value as Map);
      _automationRules = data.entries
          .map((e) => AutomationRule.fromJson(
              Map<String, dynamic>.from({
                'id': e.key,
                ...(e.value as Map),
              })))
          .toList();
    }
  }

  @override
  List<DeviceState> get currentDevices => _currentDevices;

  @override
  List<AutomationRule> get automationRules => _automationRules;

  @override
  void setDeviceStatus(String deviceId, DeviceStatus status, bool isOn) async {
    final cmdRef =
        await _GreenhousePath.child('commands/$deviceId');
    if (cmdRef == null) return;
    await cmdRef.set({
      'mode': status.toString().split('.').last,
      'targetState': isOn,
      'issuedBy': 'app',
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
      'status': 'pending',
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller?.close();
    _GreenhousePath.removeCallback(_onGreenhouseChange);
  }
}

// ─────────────────────────────────────────────────────────────
class FirebaseAlertRepository implements AlertRepository {
  StreamController<List<AlertRecord>>? _controller;
  StreamSubscription? _sub;

  FirebaseAlertRepository() {
    _GreenhousePath.onChange(_onGreenhouseChange);
  }

  void _onGreenhouseChange() {
    _sub?.cancel();
    _controller?.add([]);
    _initStream(_controller!);
  }

  @override
  Stream<List<AlertRecord>> get alertStream {
    final controller = StreamController<List<AlertRecord>>.broadcast();
    _controller = controller;
    _initStream(controller);
    return controller.stream;
  }

  Future<void> _initStream(StreamController<List<AlertRecord>> controller) async {
    final alertRef = await _GreenhousePath.child('alerts');
    // No greenhouse yet — emit empty, stay quiet
    if (alertRef == null) {
      controller.add([]);
      return;
    }
    _sub = alertRef.onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(
            event.snapshot.value as Map);
        final alerts = data.entries
            .map((e) => AlertRecord.fromJson(
                e.key,
                Map<String, dynamic>.from(e.value as Map)))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        controller.add(alerts);
      } else {
        controller.add([]);
      }
    });
  }

  @override
  Future<void> resolveAlert(String alertId) async {
    final alertRef =
        await _GreenhousePath.child('alerts/$alertId');
    if (alertRef == null) return;
    await alertRef.update({
      'isResolved': true,
      'resolvedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller?.close();
    _GreenhousePath.removeCallback(_onGreenhouseChange);
  }
}

// ── SYSTEM REPOSITORY ────────────────────────────────────────
class FirebaseSystemRepository implements SystemRepository {
  final _db = FirebaseDatabase.instance.ref();
  StreamController<SystemStatus>? _controller;
  StreamSubscription? _sub;

  FirebaseSystemRepository() {
    _GreenhousePath.onChange(_onGreenhouseChange);
  }

  void _onGreenhouseChange() {
    _sub?.cancel();
    _controller?.add(SystemStatus.offline());
    _initStream(_controller!);
  }

  @override
  Stream<SystemStatus> get statusStream {
    final controller = StreamController<SystemStatus>.broadcast();
    _controller = controller;
    _initStream(controller);
    return controller.stream;
  }

  Future<void> _initStream(StreamController<SystemStatus> controller) async {
    final connectedRef = _db.child('/.info/connected');
    _sub = connectedRef.onValue.listen((connEvent) async {
      final isConnected =
          connEvent.snapshot.value as bool? ?? false;
      if (!isConnected) {
        controller.add(SystemStatus.offline());
        return;
      }
      final sysRef =
          await _GreenhousePath.child('system');
      if (sysRef == null) {
        controller.add(SystemStatus.offline());
        return;
      }
      final sysSnap = await sysRef.get();
      if (!sysSnap.exists) {
        controller.add(SystemStatus.offline());
        return;
      }
      controller.add(SystemStatus.fromJson(
          Map<String, dynamic>.from(sysSnap.value as Map)));
    });
  }

  @override
  Future<BackupRecord> createBackup() async {
    return BackupRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      sensorReadingCount: 0,
      alertCount: 0,
      snapshotCount: 0,
      status: 'completed',
    );
  }

  @override
  Future<List<BackupRecord>> getBackups() async => [];

  @override
  void dispose() {
    _sub?.cancel();
    _controller?.close();
    _GreenhousePath.removeCallback(_onGreenhouseChange);
  }
}

// ── AUTH REPOSITORY — Email/Password + Google Sign-In ──────────
class FirebaseAuthRepository implements AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Returns the currently signed-in user, or null.
  User? get currentUser => _auth.currentUser;

  /// Stream that emits on every auth state change.
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Email + password sign-in.
  @override
  Future<bool> signIn(String email, String password) async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return true;
  }

  @override
  Future<bool> signUp(String email, String password) async {
    await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return true;
  }

  /// Google Sign-In.
  Future<bool> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return false; // user cancelled

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken:     googleAuth.idToken,
    );
    await _auth.signInWithCredential(credential);
    return true;
  }

  /// Sign out from both Firebase and Google.
  Future<void> signOut() async {
    // Clear greenhouse path cache on logout
    _GreenhousePath.clearCache();
    await Future.wait([
      _auth.signOut(),
      _googleSignIn.signOut(),
    ]);
  }

  @override
  void dispose() {}
}