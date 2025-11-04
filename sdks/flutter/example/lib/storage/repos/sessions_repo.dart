import 'package:sqflite/sqflite.dart';

class SessionsRepo {
  final Database db;
  SessionsRepo(this.db);

  Future<void> insertSession({
    required String appSessionId,
    required String userId,
    String? deviceId,
    required String startedAt,
    required String appId,
    bool dataOnCloud = false,
  }) async {
    await db.insert('dim_App_Session', {
      'app_session_id': appSessionId,
      'user_id': userId,
      'device_id': deviceId,
      'started_at': startedAt,
      'app_id': appId,
      'data_on_cloud': dataOnCloud ? 1 : 0,
    });
  }

  Future<void> endSession({
    required String appSessionId,
    required String endedAt,
    double? avgSwipScore,
  }) async {
    await db.update(
      'dim_App_Session',
      {
        'ended_at': endedAt,
        if (avgSwipScore != null) 'avg_swip_score': avgSwipScore,
      },
      where: 'app_session_id = ?',
      whereArgs: [appSessionId],
    );
  }
}


