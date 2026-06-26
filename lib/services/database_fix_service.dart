import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

/// Helper service to fix database structure issues
/// Run this once to link the current user to the existing greenhouse
class DatabaseFixService {
  static final _db = FirebaseDatabase.instance.ref();
  static final _auth = FirebaseAuth.instance;

  /// Links the current user to the existing greenhouse with code AUTM-3349
  /// This fixes the issue where users can't access data because they're not linked
  static Future<void> linkUserToGreenhouse() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in');
    }

    final userId = user.uid;

    // Check if user already has a greenhouse linked
    final userGreenhousesSnap = await _db.child('/users/$userId/greenhouses').get();
    if (userGreenhousesSnap.exists && userGreenhousesSnap.value != null) {
      print('User already has a greenhouse linked');
      return;
    }

    // Link user to the esp32 greenhouse
    await _db.child('/users/$userId/greenhouses/esp32').set('owner');

    // Update the greenhouse ownerId if it's empty
    final greenhouseSnap = await _db.child('/greenhouses/esp32').get();
    if (greenhouseSnap.exists && greenhouseSnap.value != null) {
      final data = Map<String, dynamic>.from(greenhouseSnap.value as Map);
      if (data['ownerId'] == null || data['ownerId'] == '') {
        await _db.child('/greenhouses/esp32/ownerId').set(userId);
        print('Updated greenhouse ownerId');
      }
    }

    print('Successfully linked user to greenhouse');
  }

  /// Checks the current database structure and reports issues
  static Future<Map<String, dynamic>> diagnoseDatabase() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {'error': 'User not logged in'};
    }

    final userId = user.uid;
    final result = <String, dynamic>{};

    // Check user-greenhouse linkage
    final userGreenhousesSnap = await _db.child('/users/$userId/greenhouses').get();
    result['userHasGreenhouse'] = userGreenhousesSnap.exists && userGreenhousesSnap.value != null;

    // Check greenhouse exists
    final greenhouseSnap = await _db.child('/greenhouses/esp32').get();
    result['greenhouseExists'] = greenhouseSnap.exists;

    if (greenhouseSnap.exists && greenhouseSnap.value != null) {
      final data = Map<String, dynamic>.from(greenhouseSnap.value as Map);
      result['greenhouseOwnerId'] = data['ownerId'];
      result['greenhouseJoinCode'] = data['joinCode'];
    }

    // Check data paths
    final sensorsSnap = await _db.child('/sensors').get();
    result['sensorsExist'] = sensorsSnap.exists;

    final alertsSnap = await _db.child('/alerts').get();
    result['alertsExist'] = alertsSnap.exists;

    final devicesSnap = await _db.child('/devices').get();
    result['devicesExist'] = devicesSnap.exists;

    return result;
  }
}