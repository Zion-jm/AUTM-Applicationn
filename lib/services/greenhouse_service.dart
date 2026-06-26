import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:automato/data/firebase/firebase_repositories.dart' as firebase_repo; // Namespace to prevent name collisions!

// ─────────────────────────────────────────────────────────────
// GREENHOUSE SERVICE — SECURE MULTI-USER ACCESS PORTAL
// FIXED: No auto-creation of greenhouses on login.
//        Wizard completion is tracked per-user in Firebase.
//        Greenhouse is only created when user explicitly joins.
// ─────────────────────────────────────────────────────────────

class GreenhouseService {
  static final _db = FirebaseDatabase.instance.ref();
  static final _auth = FirebaseAuth.instance;

  static String _currentUserRole = 'view';
  static String? _cachedGreenhouseId;

  static String get currentUserRole => _currentUserRole;
  static bool get isViewOnly =>
      _currentUserRole == 'view' || _currentUserRole == 'viewer';

  // ── Generate a unique join code like "AUTM-2847" ────────────
  static String _generateCode() {
    final rand = Random();
    final number = rand.nextInt(9000) + 1000; // 1000–9999
    return 'AUTM-$number';
  }

  // ═══════════════════════════════════════════════════════════
  // Check if the current user needs the setup wizard
  // Reads from Firebase so it survives app restarts and
  // works correctly across different user accounts.
  // ═══════════════════════════════════════════════════════════
  static Future<bool> checkNeedsWizard() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    final userId = user.uid;
    final snap = await _db.child('/users/$userId/hasCompletedWizard').get();

    // If the flag doesn't exist OR is false, the user needs the wizard.
    if (!snap.exists || snap.value == null) return true;
    return snap.value != true;
  }

  // ═══════════════════════════════════════════════════════════
  // Mark wizard as completed for the current user.
  // Call this AFTER the user finishes (or skips) the wizard.
  // ═══════════════════════════════════════════════════════════
  static Future<void> markWizardComplete() async {
    final user = _auth.currentUser;
    if (user == null) return;

    await _db.child('/users/${user.uid}/hasCompletedWizard').set(true);
  }

  // ═══════════════════════════════════════════════════════════
  // FIXED: initUserGreenhouse() no longer auto-creates a
  // greenhouse for new users. It only resolves an EXISTING
  // greenhouse and returns the join code. Returns empty string
  // if the user has no greenhouse yet (wizard will handle it).
  // ═══════════════════════════════════════════════════════════
  static Future<String> initUserGreenhouse() async {
    final user = _auth.currentUser;
    if (user == null) return '';

    clearGreenhouseCache();

    final userId = user.uid;
    final userSnap = await _db.child('/users/$userId/greenhouses').get();

    if (userSnap.exists && userSnap.value != null) {
      final greenhouses =
          Map<String, dynamic>.from(userSnap.value as Map);
      final greenhouseId = greenhouses.keys.first;
      _currentUserRole =
          greenhouses.values.first as String? ?? 'view';

      final codeSnap = await _db
          .child('/greenhouses/$greenhouseId/joinCode')
          .get();
      return codeSnap.value as String? ?? '';
    }

    // NEW USER: Don't create greenhouse automatically.
    // Wizard will guide them to join an existing one.
    _currentUserRole = 'view';
    return '';
  }

  // ═══════════════════════════════════════════════════════════
  // Explicitly create a greenhouse for a user.
  // This is called by the wizard when the user enters their
  // device code for the FIRST time (or when they want to create
  // a new greenhouse as an owner).
  // Returns the generated join code.
  // ═══════════════════════════════════════════════════════════
  static Future<String> createGreenhouseForUser() async {
    final user = _auth.currentUser;
    if (user == null) return '';

    final userId = user.uid;

    // Double-check they don't already have one
    final userSnap = await _db.child('/users/$userId/greenhouses').get();
    if (userSnap.exists && userSnap.value != null) {
      final greenhouses = Map<String, dynamic>.from(userSnap.value as Map);
      final greenhouseId = greenhouses.keys.first;
      _currentUserRole = greenhouses.values.first as String? ?? 'owner';
      _cachedGreenhouseId = greenhouseId;

      final codeSnap =
          await _db.child('/greenhouses/$greenhouseId/joinCode').get();
      return codeSnap.value as String? ?? '';
    }

    return _createGreenhouse(userId);
  }

  // ── Create a new greenhouse (internal) ──────────────────────
  static Future<String> _createGreenhouse(String ownerId) async {
    String joinCode = _generateCode();

    bool taken = true;
    while (taken) {
      final snap = await _db.child('/joinCodes/$joinCode').get();
      if (!snap.exists) {
        taken = false;
      } else {
        joinCode = _generateCode();
      }
    }

    final greenhouseRef = _db.child('/greenhouses').push();
    final greenhouseId = greenhouseRef.key!;

    await greenhouseRef.set({
      'joinCode': joinCode,
      'name': 'My Greenhouse',
      'ownerId': ownerId,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    await _db.child('/joinCodes/$joinCode').set(greenhouseId);
    await _db
        .child('/users/$ownerId/greenhouses/$greenhouseId')
        .set('owner');

    _currentUserRole = 'owner';
    _cachedGreenhouseId = greenhouseId;

    // Clear static repository caches
    firebase_repo.clearGreenhouseCache();

    return joinCode;
  }

  // ── Generate secure, single-use invite codes (Owner-Only) ───
  static Future<String> generateShareCode(String role) async {
    final user = _auth.currentUser;
    if (user == null) return '';

    final userSnap =
        await _db.child('/users/${user.uid}/greenhouses').get();
    if (!userSnap.exists || userSnap.value == null) return '';

    final greenhouses = Map<String, dynamic>.from(userSnap.value as Map);
    final greenhouseId = greenhouses.keys.first;

    String inviteCode = _generateCode();
    bool taken = true;
    while (taken) {
      final snap = await _db.child('/inviteCodes/$inviteCode').get();
      if (!snap.exists) {
        taken = false;
      } else {
        inviteCode = _generateCode();
      }
    }

    await _db.child('/inviteCodes/$inviteCode').set({
      'greenhouseId': greenhouseId,
      'role': role,
      'isUsed': false,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    return inviteCode;
  }

  // ── Join an existing greenhouse via code ───────────────────
  static Future<JoinResult> joinGreenhouse(String code) async {
    final user = _auth.currentUser;
    if (user == null) return JoinResult.error('Not signed in.');

    final cleanCode = code.trim().toUpperCase();

    // 1. Check single-use invite code first
    final inviteSnap = await _db.child('/inviteCodes/$cleanCode').get();
    if (inviteSnap.exists && inviteSnap.value != null) {
      final inviteData = Map<String, dynamic>.from(inviteSnap.value as Map);
      final bool isUsed = inviteData['isUsed'] ?? false;

      if (isUsed) {
        return JoinResult.error(
            'This invitation code has already been used.');
      }

      final greenhouseId = inviteData['greenhouseId'] as String;
      final role = inviteData['role'] as String? ?? 'view';

      await _db.child('/inviteCodes/$cleanCode/isUsed').set(true);
      await _db
          .child('/users/${user.uid}/greenhouses/$greenhouseId')
          .set(role);

      _currentUserRole = role;

      // Clear static repository caches so the Dashboard immediately loads the new linked data!
      firebase_repo.clearGreenhouseCache();

      final nameSnap =
          await _db.child('/greenhouses/$greenhouseId/name').get();
      final name = nameSnap.value as String? ?? 'Greenhouse';

      return JoinResult.success(name);
    }

    // 2. Permanent join code (from ESP32 label)
    final snap = await _db.child('/joinCodes/$cleanCode').get();
    if (!snap.exists) {
      return JoinResult.error(
          'Code not found. Check the label on your device.');
    }

    final greenhouseId = snap.value as String;

    final existingSnap = await _db
        .child('/users/${user.uid}/greenhouses/$greenhouseId')
        .get();
    if (existingSnap.exists) {
      return JoinResult.error(
          'You are already connected to this greenhouse.');
    }

    await _db
        .child('/users/${user.uid}/greenhouses/$greenhouseId')
        .set('owner');

    _currentUserRole = 'owner';

    // Clear repository cache to force dashboard data reload!
    firebase_repo.clearGreenhouseCache();

    final nameSnap =
        await _db.child('/greenhouses/$greenhouseId/name').get();
    final name = nameSnap.value as String? ?? 'Greenhouse';

    return JoinResult.success(name);
  }

  // ── Get current user's join code ───────────────────────────
  static Future<String> getMyJoinCode() async {
    final user = _auth.currentUser;
    if (user == null) return '';

    final userSnap =
        await _db.child('/users/${user.uid}/greenhouses').get();
    if (!userSnap.exists || userSnap.value == null) return '';

    final greenhouses = Map<String, dynamic>.from(userSnap.value as Map);
    final greenhouseId = greenhouses.keys.first;

    final codeSnap =
        await _db.child('/greenhouses/$greenhouseId/joinCode').get();
    return codeSnap.value as String? ?? '';
  }

  // ── Get current user's role ────────────────────────────────
  static Future<String> getMyRole() async {
    final user = _auth.currentUser;
    if (user == null) return 'view';

    final userSnap =
        await _db.child('/users/${user.uid}/greenhouses').get();
    if (!userSnap.exists || userSnap.value == null) return 'view';

    final greenhouses = Map<String, dynamic>.from(userSnap.value as Map);
    _currentUserRole = greenhouses.values.first as String? ?? 'view';
    return _currentUserRole;
  }

  // ═══════════════════════════════════════════════════════════
  // Clear cached greenhouse path. Call this on logout
  // or when switching users to prevent stale data.
  // ═══════════════════════════════════════════════════════════
  static void clearGreenhouseCache() {
    _cachedGreenhouseId = null;
    _currentUserRole = 'view';

    // Clear actual DatabaseRepository static cache safely via namespace
    firebase_repo.clearGreenhouseCache();
  }

  // ═══════════════════════════════════════════════════════════
  // Clear ALL user-specific state. Call this on logout.
  // ═══════════════════════════════════════════════════════════
  static void clearAllUserState() {
    clearGreenhouseCache();
  }
}

// ─────────────────────────────────────────────────────────────
class JoinResult {
  final bool success;
  final String? greenhouseName;
  final String? errorMessage;

  const JoinResult._({
    required this.success,
    this.greenhouseName,
    this.errorMessage,
  });

  factory JoinResult.success(String name) =>
      JoinResult._(success: true, greenhouseName: name);

  factory JoinResult.error(String message) =>
      JoinResult._(success: false, errorMessage: message);
}
