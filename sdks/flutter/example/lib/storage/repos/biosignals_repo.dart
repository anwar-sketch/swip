import 'package:sqflite/sqflite.dart';

class BiosignalsRepo {
  final Database db;
  BiosignalsRepo(this.db);

  Future<void> insertBiosignal({
    required String appBiosignalId,
    required String appSessionId,
    required String timestamp,
    double? heartRate,
    double? hrvSdnn,
    double? ibi,
  }) async {
    await db.insert('dim_App_biosignals', {
      'app_biosignal_id': appBiosignalId,
      'app_session_id': appSessionId,
      'timestamp': timestamp,
      'heart_rate': heartRate,
      'hrv_sdnn': hrvSdnn,
      'ibi': ibi,
    });
  }
}
