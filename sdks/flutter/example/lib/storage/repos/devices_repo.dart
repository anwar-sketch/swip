import 'package:sqflite/sqflite.dart';

class DevicesRepo {
  final Database db;
  DevicesRepo(this.db);

  Future<void> upsertDevice({
    required String deviceId,
    String? platform,
    String? model,
    String? osVersion,
  }) async {
    await db.insert(
      'dim_devices',
      {
        'device_id': deviceId,
        'platform': platform,
        'model': model,
        'os_version': osVersion,
        'created_datetime': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}

