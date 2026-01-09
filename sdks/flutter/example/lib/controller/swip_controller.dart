import 'dart:async';
import 'package:flutter/material.dart';
import 'package:swip/swip.dart';
import '../storage/database.dart';
import '../storage/storage_service.dart';

/// Controller for SWIP SDK integration
/// Manages SWIP sessions, scores, and emotions with SQLite logging
class SwipController extends ChangeNotifier {
  // ──────────────────────────────────────────────────────────────
  // Dependencies
  // ──────────────────────────────────────────────────────────────
  SwipSdkManager? _sdk;
  final StorageService _storage = StorageService();
  StreamSubscription<SwipScoreResult>? _scoreSubscription;
  StreamSubscription<EmotionResult>? _emotionSubscription;
  Timer? _elapsedTimer; // Timer to update elapsed time display

  // ──────────────────────────────────────────────────────────────
  // State
  // ──────────────────────────────────────────────────────────────
  bool _isInitialized = false;
  bool _isSessionActive = false;
  String _status = 'Not initialized';
  String _error = '';
  SwipScoreResult? _currentScore;
  EmotionResult? _currentEmotion;
  String? _activeSessionId;
  DateTime? _sessionStartTime;
  final List<SwipSessionResults> _sessionHistory = [];

  // ──────────────────────────────────────────────────────────────
  // Getters
  // ──────────────────────────────────────────────────────────────
  bool get isInitialized => _isInitialized;
  bool get isSessionActive => _isSessionActive;
  String get status => _status;
  String get error => _error;
  SwipScoreResult? get currentScore => _currentScore;
  EmotionResult? get currentEmotion => _currentEmotion;
  String? get activeSessionId => _activeSessionId;
  DateTime? get sessionStartTime => _sessionStartTime;
  List<SwipSessionResults> get sessionHistory => _sessionHistory;
  StorageService get storage => _storage;

  /// Get elapsed time since session started
  Duration get elapsedTime {
    if (_sessionStartTime == null) {
      return Duration.zero;
    }
    return DateTime.now().difference(_sessionStartTime!);
  }

  // ──────────────────────────────────────────────────────────────
  // Initialization
  // ──────────────────────────────────────────────────────────────
  SwipController({required String userId}) {
    _userId = userId;
    // Initialize SDK asynchronously
    _initializeSdk();
  }

  String _userId = '';

  void _initializeSdk() {
    // Initialize SDK asynchronously without blocking constructor
    debugPrint('🔧 [SwipController] Starting SDK initialization...');
    Future.microtask(() async {
      try {
        // Warm up DB and ensure user exists
        await AppDatabase.instance.database;
        await _storage.initUser(userId: _userId);

        // Enable consent by default for example app (so storage works)
        await _storage.setConsent(userId: _userId, enabled: true);

        // Create SWIP SDK configuration
        // Using same emotion config as emotion SDK for consistency
        // Note: SWIP SDK will initialize wear SDK internally
        // IMPORTANT: SwipSdkManager now uses nozipmap model (same as synheart-poc-dart)
        // The modelId will be automatically read from the loaded model's metadata
        final config = SwipSdkConfig(
          emotionConfig: const EmotionConfig(
            modelId:
                'extratrees_chest_ecg_w60s5_binary_v1_0', // Will be overridden by model's actual modelId
            window: Duration(seconds: 60),
            step: Duration(seconds: 5),
            minRrCount: 30, // Match SwipSdkManager's minRrCount
            returnAllProbas: true,
          ),
          enableLogging: true,
        );

        debugPrint('📋 [SwipController] Creating SwipSdkManager...');
        // SWIP SDK will initialize wear SDK internally (no wear parameter passed)
        _sdk = SwipSdkManager(
          config: config,
        );

        debugPrint('📦 [SwipController] Initializing SWIP SDK...');
        await _sdk!.initialize();

        // Attach storage service to manager for SQLite logging (after initialization)
        _storage.attachToManager(_sdk!);

        // Subscribe to score stream
        _scoreSubscription = _sdk!.scoreStream.listen(
          (score) {
            _currentScore = score;
            debugPrint(
              '📊 [SwipController] SWIP Score received: ${score.swipScore.toStringAsFixed(1)}, Emotion: ${score.dominantEmotion}',
            );
            notifyListeners();
          },
          onError: (error) {
            debugPrint('❌ [SwipController] Score stream error: $error');
            _updateState(
              error: 'Score stream error: $error',
            );
          },
        );

        debugPrint('✅ [SwipController] Score stream subscription set up');

        // Subscribe to emotion stream
        _emotionSubscription = _sdk!.emotionStream.listen(
          (emotion) {
            _currentEmotion = emotion;
            debugPrint(
              '🎭 [SwipController] Emotion received: ${emotion.emotion}, Confidence: ${emotion.confidence.toStringAsFixed(2)}',
            );
            notifyListeners();
          },
          onError: (error) {
            debugPrint('❌ [SwipController] Emotion stream error: $error');
          },
        );

        debugPrint('✅ [SwipController] Emotion stream subscription set up');

        _updateState(
          isInitialized: true,
          status: 'SWIP SDK initialized and ready',
          error: '',
        );

        debugPrint('✅ [SwipController] SWIP SDK initialized successfully');
      } catch (e, stackTrace) {
        debugPrint('❌ [SwipController] Failed to initialize SWIP SDK: $e');
        debugPrint('❌ [SwipController] Stack trace: $stackTrace');
        _updateState(
          isInitialized: false,
          status: 'Initialization failed',
          error: 'Failed to initialize SWIP SDK: $e',
        );
      }
    });
  }

  // ──────────────────────────────────────────────────────────────
  // State Management
  // ──────────────────────────────────────────────────────────────
  void _updateState({
    bool? isInitialized,
    bool? isSessionActive,
    String? status,
    String? error,
    SwipScoreResult? currentScore,
    EmotionResult? currentEmotion,
    String? activeSessionId,
    DateTime? sessionStartTime,
  }) {
    bool changed = false;

    if (isInitialized != null && isInitialized != _isInitialized) {
      _isInitialized = isInitialized;
      changed = true;
    }
    if (isSessionActive != null && isSessionActive != _isSessionActive) {
      _isSessionActive = isSessionActive;
      changed = true;
    }
    if (status != null && status != _status) {
      _status = status;
      changed = true;
    }
    if (error != null && error != _error) {
      _error = error;
      changed = true;
    }
    if (currentScore != null && currentScore != _currentScore) {
      _currentScore = currentScore;
      changed = true;
    }
    if (currentEmotion != null && currentEmotion != _currentEmotion) {
      _currentEmotion = currentEmotion;
      changed = true;
    }
    if (activeSessionId != null && activeSessionId != _activeSessionId) {
      _activeSessionId = activeSessionId;
      changed = true;
    }
    if (sessionStartTime != null && sessionStartTime != _sessionStartTime) {
      _sessionStartTime = sessionStartTime;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Session Management
  // ──────────────────────────────────────────────────────────────
  Future<void> startSession({String appId = 'swip_example_app'}) async {
    debugPrint('🚀 [SwipController] startSession() called');
    if (!_isInitialized || _sdk == null) {
      debugPrint('❌ [SwipController] Cannot start: SDK not initialized');
      _updateState(
        error: 'SWIP SDK not initialized',
        status: 'Not initialized',
      );
      return;
    }

    if (_isSessionActive) {
      debugPrint(
          '⚠️ [SwipController] Session already active, ignoring start request');
      return;
    }

    try {
      // Start session with app ID
      final sessionId = await _sdk!.startSession(
        appId: appId,
        metadata: {
          'platform': 'flutter',
          'version': '1.0.0',
        },
      );

      // Start session in storage service for SQLite logging
      debugPrint('💾 [SwipController] Starting storage session...');
      await _storage.startSession(
        userId: _userId,
        appId: appId,
        deviceId: null,
        deviceSource: null,
      );
      debugPrint('✅ [SwipController] Storage session started');

      final startTime = DateTime.now();

      // Clear previous session data before starting new session
      _currentScore = null;
      _currentEmotion = null;

      _updateState(
        isSessionActive: true,
        activeSessionId: sessionId,
        sessionStartTime: startTime,
        status: 'Session active - measuring wellness impact',
        error: '',
        currentScore: null, // Reset current score for new session
        currentEmotion: null, // Reset current emotion for new session
      );

      // Force UI update to clear previous session data
      notifyListeners();

      // Start elapsed time timer to update UI every second
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_isSessionActive) {
          timer.cancel();
          return;
        }
        notifyListeners(); // Update UI to show new elapsed time
      });

      debugPrint('✅ [SwipController] Session started: $sessionId');
    } catch (e, stackTrace) {
      debugPrint('❌ [SwipController] Failed to start session: $e');
      debugPrint('❌ [SwipController] Stack trace: $stackTrace');
      _updateState(
        isSessionActive: false,
        error: 'Failed to start session: $e',
        status: 'Failed to start session',
      );
    }
  }

  Future<void> stopSession() async {
    debugPrint('🛑 [SwipController] stopSession() called');
    if (!_isSessionActive || _sdk == null) {
      debugPrint('⚠️ [SwipController] No active session to stop');
      return;
    }

    try {
      final results = await _sdk!.stopSession();

      // End session in storage service for SQLite logging
      final avg = results.scores.isNotEmpty
          ? results.scores.map((e) => e.swipScore).reduce((a, b) => a + b) /
              results.scores.length
          : null;
      await _storage.endSession(averageScore: avg);

      // Add to history
      _sessionHistory.insert(0, results);
      if (_sessionHistory.length > 50) {
        _sessionHistory.removeLast(); // Keep only last 50 sessions
      }

      final summary = results.getSummary();
      debugPrint(
        '📊 [SwipController] Session ended. Average score: ${summary['average_swip_score']?.toStringAsFixed(1)}, Duration: ${summary['duration_seconds']}s',
      );

      // Stop elapsed time timer
      _elapsedTimer?.cancel();
      _elapsedTimer = null;

      _updateState(
        isSessionActive: false,
        activeSessionId: null,
        sessionStartTime: null,
        status:
            'Session ended - Average score: ${summary['average_swip_score']?.toStringAsFixed(1)}',
        currentScore: null,
        currentEmotion: null,
      );

      debugPrint('✅ [SwipController] Session stopped successfully');
    } catch (e, stackTrace) {
      debugPrint('❌ [SwipController] Failed to stop session: $e');
      debugPrint('❌ [SwipController] Stack trace: $stackTrace');
      _updateState(
        error: 'Failed to stop session: $e',
        status: 'Error stopping session',
      );
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Session History
  // ──────────────────────────────────────────────────────────────
  Future<void> loadSessionHistory() async {
    // History is already maintained in _sessionHistory
    debugPrint(
        '📚 [SwipController] Session history loaded: ${_sessionHistory.length} sessions');
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────────
  // Consent Management (delegated to StorageService)
  // ──────────────────────────────────────────────────────────────
  Future<void> setConsent(
      {required String userId, required bool enabled}) async {
    await _storage.setConsent(userId: userId, enabled: enabled);
    notifyListeners();
  }

  Future<void> setCloudSyncConsent(
      {required String userId, required bool enabled}) async {
    await _storage.setCloudSyncConsent(userId: userId, enabled: enabled);
    notifyListeners();
  }

  @override
  void dispose() {
    debugPrint('🧹 [SwipController] dispose() called');
    _elapsedTimer?.cancel();
    _scoreSubscription?.cancel();
    _emotionSubscription?.cancel();
    _storage.dispose();
    _sdk?.dispose();
    super.dispose();
  }
}
