import 'dart:async';

import 'package:swip/swip.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'repos/apps_repo.dart';
import 'repos/biosignals_repo.dart';
import 'repos/consents_repo.dart';
import 'repos/devices_repo.dart';
import 'repos/emotions_repo.dart';
import 'repos/sessions_repo.dart';
import 'repos/users_repo.dart';

class StorageService {
  final _uuid = const Uuid();

  String? _currentSessionId;
  StreamSubscription? _emotionSub;
  StreamSubscription? _scoreSub;
  bool _consentEnabled = false;

  Future<void> initUser({required String userId}) async {
    final db = await AppDatabase.instance.database;
    final users = UsersRepo(db);
    await users.upsertUser(userId: userId, createdAt: DateTime.now().toUtc().toIso8601String());

    // Check existing consent
    final consents = ConsentsRepo(db);
    final status = await consents.getConsentStatus(userId: userId, type: 'local_storage');
    _consentEnabled = status == 'active';
  }

  Future<void> setConsent({required String userId, required bool enabled}) async {
    _consentEnabled = enabled;
    final db = await AppDatabase.instance.database;
    final consents = ConsentsRepo(db);
    await consents.upsertConsent(
      userId: userId,
      type: 'local_storage',
      status: enabled ? 'active' : 'revoked',
    );
  }

  bool get consentEnabled => _consentEnabled;

  Future<void> startSession({
    required String userId,
    required String appId,
    String? deviceId,
    String? deviceSource,
  }) async {
    if (!_consentEnabled) return;

    _currentSessionId = _uuid.v4();
    final db = await AppDatabase.instance.database;

    // Ensure app exists
    final apps = AppsRepo(db);
    await apps.upsertApp(
      appId: appId,
      appName: 'SWIP Example App',
      appVersion: '1.0.0',
      category: 'Wellness',
    );

    // Ensure device exists
    if (deviceId != null) {
      final devices = DevicesRepo(db);
      await devices.upsertDevice(
        deviceId: deviceId,
        platform: deviceSource ?? 'unknown',
      );
    }

    final sessions = SessionsRepo(db);
    await sessions.insertSession(
      appSessionId: _currentSessionId!,
      userId: userId,
      deviceId: deviceId,
      startedAt: DateTime.now().toUtc().toIso8601String(),
      appId: appId,
    );
  }

  Future<void> endSession({double? averageScore}) async {
    if (_currentSessionId == null) return;
    final db = await AppDatabase.instance.database;
    final sessions = SessionsRepo(db);
    await sessions.endSession(
      appSessionId: _currentSessionId!,
      endedAt: DateTime.now().toUtc().toIso8601String(),
      avgSwipScore: averageScore,
    );
    _currentSessionId = null;
  }

  void attachToManager(SwipSdkManager manager) async {
    // Emotions → persist to dim_emotions and a minimal biosignal row
    _emotionSub?.cancel();
    _emotionSub = manager.emotionStream.listen((emotion) async {
      if (_currentSessionId == null || !_consentEnabled) return;
      final db = await AppDatabase.instance.database;
      final bios = BiosignalsRepo(db);
      final emos = EmotionsRepo(db);

      final appBiosignalId = _uuid.v4();
      final ts = emotion.timestamp.toUtc().toIso8601String();

      // Minimal biosignal: heart_rate from features if available; leave others null
      final hr = emotion.features['hr_mean'];
      final sdnn = emotion.features['sdnn'];
      await bios.insertBiosignal(
        appBiosignalId: appBiosignalId,
        appSessionId: _currentSessionId!,
        timestamp: ts,
        heartRate: hr,
        hrvSdnn: sdnn,
      );

      // Emotion
      await emos.insertEmotion(
        appBiosignalId: appBiosignalId,
        swipScore: null, // will be backfilled when score arrives
        physSubscore: null,
        emoSubscore: null,
        confidence: emotion.confidence,
        dominantEmotion: emotion.emotion,
        modelId: (emotion.model['id'] ?? manager.config.emotionConfig.modelId).toString(),
      );
    });

    // Scores → link to latest emotion row
    _scoreSub?.cancel();
    _scoreSub = manager.scoreStream.listen((score) async {
      if (_currentSessionId == null || !_consentEnabled) return;
      final db = await AppDatabase.instance.database;
      final emos = EmotionsRepo(db);
      
      // Link score to the most recent emotion for this session
      await emos.updateLatestEmotionWithScore(
        appSessionId: _currentSessionId!,
        swipScore: score.swipScore,
        // Note: physSubscore and emoSubscore not available in SwipScoreResult currently
      );
    });
  }

  Future<void> dispose() async {
    await _emotionSub?.cancel();
    await _scoreSub?.cancel();
  }
}


