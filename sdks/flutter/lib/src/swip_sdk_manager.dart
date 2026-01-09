import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:swip/swip.dart' hide ConsentManager, ConsentStatus;
import 'package:swip_core/swip_core.dart' show EmotionSnapshot;
import 'package:synheart_wear/synheart_wear.dart';
import 'package:synheart_emotion/synheart_emotion.dart'
    show EmotionEngine, EmotionConfig, EmotionResult, OnnxEmotionModel;
import 'models.dart';
import 'errors.dart';

/// SWIP SDK Manager - Main entry point for the SDK
///
/// Integrates:
/// - synheart_wear: Reads HR, HRV, motion data
/// - synheart_emotion: Runs emotion inference models
/// - swip_core: Computes SWIP Score
class SwipSdkManager {
  // Core components
  final SynheartWear _wear;
  EmotionEngine? _emotionEngine;
  final SwipEngine _swipEngine;

  // State management
  bool _initialized = false;
  bool _isWearInitialized = false;
  bool _isRunning = false;
  String? _activeSessionId;

  // Stream controllers
  final _scoreStreamController = StreamController<SwipScoreResult>.broadcast();
  final _emotionStreamController = StreamController<EmotionResult>.broadcast();

  // Subscriptions
  StreamSubscription<WearMetrics>? _wearSubscription;
  Timer? _emotionProcessor;

  // Configuration
  final SwipSdkConfig config;

  // Session data
  final List<SwipScoreResult> _sessionScores = [];
  final List<EmotionResult> _sessionEmotions = [];
  WearMetrics?
      _latestWearMetrics; // Cache latest metrics from stream to avoid duplicate readMetrics() calls
  DateTime? _lastBufferStatsLog; // Track when we last logged buffer stats

  SwipSdkManager({
    required this.config,
    SynheartWear? wear,
    EmotionEngine? emotionEngine,
    SwipEngine? swipEngine,
  })  : _wear = wear ??
            SynheartWear(
              config: SynheartWearConfig.withAdapters(
                {DeviceAdapter.appleHealthKit},
              ),
            ),
        _emotionEngine = emotionEngine,
        _swipEngine = swipEngine ??
            SwipEngineFactory.createDefault(
              config: config.swipConfig,
            );

  /// Initialize the SDK
  ///
  /// This method follows the synheart-poc-dart pattern:
  /// 1. Initialize emotion engine
  /// 2. Initialize wearable SDK first (this will request permissions if needed)
  /// 3. Check if permissions are already granted
  /// 4. If not, explicitly request permissions with platform-specific types
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    try {
      // Initialize emotion engine if not provided
      // Using synheart-emotionv2 initialization pattern with ONNX model
      if (_emotionEngine == null) {
        try {
          // Load ONNX model first (async operation)
          // Use nozipmap version (same as synheart-poc-dart) which outputs probabilities directly
          // The modelId will be read from the model's metadata
          final onnxModel = await OnnxEmotionModel.loadFromAsset(
            modelAssetPath: 'assets/ml/ExtraTrees_60_5_nozipmap.onnx',
            metaAssetPath: "assets/ml/ExtraTrees_metadata_60_5_nozipmap.json",
          );

          // Create emotion config with window and step from SDK config
          // Use modelId from loaded model to ensure consistency
          final emotionConfig = EmotionConfig(
            modelId: onnxModel.modelId, // Use actual modelId from loaded model
            window: Duration(seconds: 60),
            step: Duration(seconds: 5),
            minRrCount: 30,
            returnAllProbas: config.emotionConfig.returnAllProbas,
            hrBaseline: config.emotionConfig.hrBaseline,
            priors: config.emotionConfig.priors,
          );

          // Create engine with loaded ONNX model
          // Enable logging to help debug issues
          _emotionEngine = EmotionEngine.fromPretrained(
            emotionConfig,
            model: onnxModel,
            onLog: (level, message, {context}) {
              print('🧠 [EmotionEngine] [$level] $message');
              if (context != null && context.isNotEmpty) {
                print('   Context: $context');
              }
            },
          );
        } catch (e) {
          throw InitializationError('Failed to initialize emotion engine: $e');
        }
      }

      // Initialize SDK first (only when user requests initialization)
      // This is the first time we initialize, so it won't trigger permission dialogs
      // Following synheart-poc-dart pattern: initialize first, then check permissions
      // Note: initialize() might fail if Health Connect is not available or permissions are denied,
      // but we catch and continue to check/request permissions explicitly below
      try {
        await _wear.initialize();
        _isWearInitialized = true;
      } catch (e) {
        // If initialization fails (e.g., Health Connect not available, permissions denied),
        // we'll still try to request permissions explicitly below
        // This matches synheart-poc-dart pattern: initialize() can fail, continue anyway
        _isWearInitialized = false;
        print(
            '⚠️ synheart_wear.initialize() failed (continuing to check permissions): $e');
      }

      // First, check if permissions are already granted
      // This matches synheart-poc-dart pattern: check permissions after initialize()
      final existingConsents = ConsentManager.getAllConsents();
      final hasExistingPermissions = existingConsents.values.any(
        (status) => status == ConsentStatus.granted,
      );

      bool granted = false;

      if (hasExistingPermissions) {
        // Permissions already exist, just verify they're still valid
        granted = true;
        // SDK should already be initialized from the try-catch above
        if (!_isWearInitialized) {
          try {
            await _wear.initialize();
            _isWearInitialized = true;
          } catch (e) {
            _isWearInitialized = false;
            print('⚠️ Failed to initialize even with existing permissions: $e');
          }
        }
      } else {
        // No existing permissions, request them explicitly with platform-specific types
        // Request permissions for health data
        // Note: Health Connect on Android doesn't support HRV_SDNN, so exclude it on Android
        Set<PermissionType> permissions;
        if (Platform.isAndroid) {
          // Health Connect doesn't support DISTANCE_WALKING_RUNNING
          // Request only supported data types
          permissions = {
            PermissionType.heartRate,
            PermissionType.heartRateVariability, // RMSSD on Android
            PermissionType.steps,
            PermissionType.calories,
            // Distance is not supported by Health Connect
          };
        } else {
          // iOS HealthKit supports all types
          permissions = {
            PermissionType.heartRate,
            PermissionType.heartRateVariability,
            PermissionType.steps,
            PermissionType.calories,
            PermissionType.distance,
          };
        }

        // Request permissions explicitly - this will open Health Connect UI on Android
        // This is the key call that shows the Health Connect permission dialog
        final result = await _wear.requestPermissions(
          permissions: permissions,
          reason:
              'This app needs access to your health data from Apple Health or Health Connect to provide wellness insights.',
        );

        // Check if any permissions were granted
        granted = result.values.any(
          (status) => status == ConsentStatus.granted,
        );

        if (!granted) {
          // If permissions were not granted, mark as initialized anyway
          // The app can continue, but SWIP scores won't be available
          _isWearInitialized = false;
        } else {
          // Permissions granted, ensure wearable SDK is initialized
          if (!_isWearInitialized) {
            try {
              await _wear.initialize();
              _isWearInitialized = true;
            } catch (e) {
              // If initialization still fails after permissions are granted,
              // there may be another issue (e.g., Health Connect not properly configured)
              _isWearInitialized = false;
              print('⚠️ Failed to initialize after permissions granted: $e');
            }
          }
        }
      }

      _initialized = true;
    } catch (e) {
      throw InitializationError('Failed to initialize SWIP SDK: $e');
    }
  }

  /// Start a session for an app
  Future<String> startSession({
    required String appId,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_initialized) {
      throw InvalidConfigurationError('SWIP SDK not initialized');
    }

    if (_isRunning) {
      throw SessionError('Session already in progress');
    }

    // Generate session ID
    _activeSessionId = '${DateTime.now().millisecondsSinceEpoch}_$appId';

    try {
      // Clear emotion engine buffer to remove any old data (including motion data)
      _emotionEngine?.clear();
      print(
          '🧹 [SwipSdkManager] Cleared emotion engine buffer for new session');

      // Initialize wearable SDK if not already initialized
      if (!_isWearInitialized) {
        print(
            '🔧 [SwipSdkManager] Wearable SDK not initialized, initializing now...');
        await _wear.initialize();
        _isWearInitialized = true;
        print('✅ [SwipSdkManager] Wearable SDK initialized');
      } else {
        print('✅ [SwipSdkManager] Wearable SDK already initialized');
      }

      // Subscribe to HR stream - this provides HR data and HRV data when available
      // Note: readMetrics() returns all available metrics including HRV, so we don't need
      // a separate HRV stream subscription. Using a single stream reduces Health Connect
      // API calls and prevents rate limiting.
      // Increased interval to 5 seconds to reduce Health Connect rate limit issues
      // (Health Connect typically limits to ~30-60 requests per minute)
      print('📡 [SwipSdkManager] Setting up HR stream subscription...');
      _wearSubscription =
          _wear.streamHR(interval: const Duration(seconds: 5)).listen(
        (metrics) {
          // Handle HR stream metrics - includes both HR and HRV data
          _handleWearMetrics(metrics);
        },
        onError: (error) {
          print('❌ [SwipSdkManager] HR stream error: $error');
        },
        onDone: () {
          print('⚠️ [SwipSdkManager] HR stream closed');
        },
      );
      print('✅ [SwipSdkManager] HR stream subscription established');

      // Note: Removed HRV stream subscription to reduce Health Connect API calls.
      // The HR stream already includes HRV data when available via readMetrics(),
      // so a separate HRV stream causes duplicate queries and rate limiting.

      // Start emotion processing timer (1 Hz)
      print('⏰ [SwipSdkManager] Starting emotion processing timer (1 Hz)');
      _emotionProcessor = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _processEmotionUpdates(),
      );

      _isRunning = true;
      _lastBufferStatsLog = null; // Reset buffer stats logging for new session
      print(
          '✅ [SwipSdkManager] Session started successfully: $_activeSessionId');

      return _activeSessionId!;
    } catch (e) {
      await stopSession();
      throw SessionError('Failed to start session: $e');
    }
  }

  /// Stop the current session
  Future<SwipSessionResults> stopSession() async {
    if (!_isRunning || _activeSessionId == null) {
      throw SessionError('No active session');
    }

    try {
      // Set _isRunning to false first to prevent processing any late-arriving metrics
      _isRunning = false;

      // Cancel subscriptions - this stops listening to streams
      await _wearSubscription?.cancel();
      _wearSubscription = null;

      // Stop timer
      _emotionProcessor?.cancel();
      _emotionProcessor = null;

      // Note: synheart_wear timers will automatically stop when hasListener becomes false
      // However, there may be a brief delay (up to 2-5 seconds) before the timer checks hasListener
      // The _isRunning guard in _handleWearMetrics ensures we ignore any late-arriving data

      // Create session results
      final results = SwipSessionResults(
        sessionId: _activeSessionId!,
        scores: List.from(_sessionScores),
        emotions: List.from(_sessionEmotions),
        startTime: _sessionScores.isNotEmpty
            ? _sessionScores.first.timestamp
            : DateTime.now(),
        endTime: _sessionScores.isNotEmpty
            ? _sessionScores.last.timestamp
            : DateTime.now(),
      );

      // Clear session data
      _clearSession();
      _latestWearMetrics = null; // Clear cached metrics

      return results;
    } catch (e) {
      throw SessionError('Failed to stop session: $e');
    }
  }

  /// Handle incoming wearable metrics from either HR or HRV stream
  void _handleWearMetrics(WearMetrics metrics) {
    // Ignore metrics if session is not running (defense against late-arriving data after stopSession)
    if (!_isRunning) {
      print(
          '⚠️ [SwipSdkManager] Received metrics but session not running, ignoring');
      return;
    }

    // Cache latest metrics to avoid duplicate readMetrics() calls
    _latestWearMetrics = metrics;

    // Extract HR and HRV
    final hr = metrics.getMetric(MetricType.hr)?.toDouble();
    final hrvSdnn = metrics.getMetric(MetricType.hrvSdnn)?.toDouble();
    final hrvRmssd = metrics.getMetric(MetricType.hrvRmssd)?.toDouble();
    final motion = metrics.metrics['motion']?.toDouble() ?? 0.0;

    print(
        '💓 [SwipSdkManager] Wearable metrics received - HR: ${hr?.toStringAsFixed(1) ?? "null"}, HRV_SDNN: ${hrvSdnn?.toStringAsFixed(1) ?? "null"}, HRV_RMSSD: ${hrvRmssd?.toStringAsFixed(1) ?? "null"}, Motion: ${motion.toStringAsFixed(2)}');

    if (hr == null) {
      print('⚠️ [SwipSdkManager] No heart rate in metrics, skipping');
      return;
    }

    // Use real RR intervals if available, otherwise generate synthetic ones
    List<double> rrIntervals;
    if (metrics.rrMs != null && metrics.rrMs!.isNotEmpty) {
      rrIntervals = metrics.rrMs!;
    } else {
      // Generate synthetic RR intervals from HR and HRV data (or just HR with default variability)
      rrIntervals = _generateRRIntervalsFromHRV(
        hr: hr,
        hrvSdnn: hrvSdnn,
        hrvRmssd: hrvRmssd,
      );
    }

    // Push to emotion engine
    try {
      // Use current time for timestamp - emotion engine needs real-time window calculations
      // The metrics.timestamp may be when data was originally recorded (could be old),
      // but for the sliding window, we need when we're processing it now
      final now = DateTime.now().toUtc();

      print(
          '🧠 [SwipSdkManager] Pushing data to emotion engine - HR: ${hr.toStringAsFixed(1)}, RR intervals: ${rrIntervals.length}');
      // Note: Don't pass motion data for 14-feature ExtraTrees models
      // The model expects exactly 14 features, and motion would add a 15th feature
      _emotionEngine?.push(
        hr: hr,
        rrIntervalsMs: rrIntervals,
        timestamp: now,
        motion: null, // ExtraTrees models don't use motion data
      );
    } catch (e) {
      print('❌ [SwipSdkManager] Error pushing to emotion engine: $e');
    }
  }

  /// Process emotion updates from the emotion engine
  Future<void> _processEmotionUpdates() async {
    if (_emotionEngine == null) {
      return;
    }

    try {
      // Use consumeReadyAsync() for ONNX models (async support)
      // This properly handles both ONNX and Linear SVM models
      List<EmotionResult> emotionResults;
      try {
        emotionResults = await _emotionEngine!.consumeReadyAsync();
      } catch (e, stackTrace) {
        print('❌ [SwipSdkManager] Error calling consumeReadyAsync: $e');
        print('❌ [SwipSdkManager] Stack trace: $stackTrace');
        return;
      }

      if (emotionResults.isEmpty) {
        // Log buffer stats periodically (every 15 seconds) to help diagnose
        final now = DateTime.now();
        if (_lastBufferStatsLog == null ||
            now.difference(_lastBufferStatsLog!).inSeconds >= 15) {
          final bufferStats = _emotionEngine!.getBufferStats();
          final bufferCount = bufferStats['count'] as int;
          final bufferDurationSeconds =
              (bufferStats['duration_ms'] as int) / 1000.0;
          final rrCount = bufferStats['rr_count'] as int;
          final requiredWindowSeconds = _emotionEngine!.config.window.inSeconds;
          final requiredRrCount = _emotionEngine!.config.minRrCount;
          final stepSeconds = _emotionEngine!.config.step.inSeconds;

          if (bufferDurationSeconds < requiredWindowSeconds - 2) {
            print(
                '⏳ [SwipSdkManager] Emotion engine not ready: need ${requiredWindowSeconds}s window, have ${bufferDurationSeconds.toStringAsFixed(1)}s (need ${(requiredWindowSeconds - bufferDurationSeconds).toStringAsFixed(1)}s more)');
          } else if (rrCount < requiredRrCount) {
            print(
                '⏳ [SwipSdkManager] Emotion engine not ready: need $requiredRrCount RR intervals, have $rrCount (need ${requiredRrCount - rrCount} more)');
          } else {
            // Check if model is loaded
            final modelType =
                _emotionEngine!.model?.runtimeType.toString() ?? 'null';
            print(
                '⏳ [SwipSdkManager] Emotion engine has enough data (${bufferDurationSeconds.toStringAsFixed(1)}s window, $rrCount RR intervals, ${bufferCount} data points) but no results yet. Step interval: ${stepSeconds}s, Model: $modelType');
            print(
                '   This usually means step interval throttling (waiting for ${stepSeconds}s since last emission) or feature extraction/inference failed. Check emotion engine logs above for details.');
          }
          _lastBufferStatsLog = now;
        }
        return;
      }

      // Reset buffer stats log when we get results
      _lastBufferStatsLog = null;

      // Get latest emotion result
      final latestEmotion = emotionResults.last;
      _sessionEmotions.add(latestEmotion);

      print(
          '🎭 [SwipSdkManager] Emotion result: ${latestEmotion.emotion} (confidence: ${latestEmotion.confidence.toStringAsFixed(2)})');

      // Emit emotion stream
      if (_emotionStreamController.isClosed) {
        print(
            '⚠️ [SwipSdkManager] Emotion stream controller is closed, cannot emit');
        return;
      }

      _emotionStreamController.add(latestEmotion);

      // Get current physiological data for SWIP computation
      // Use cached metrics from stream instead of calling readMetrics() again
      // This avoids duplicate API calls to the health SDK
      try {
        final lastMetrics = _latestWearMetrics;
        if (lastMetrics == null) {
          print(
              '⚠️ [SwipSdkManager] No cached metrics, reading from wear SDK...');
          // Fallback to readMetrics only if we don't have cached metrics yet
          _latestWearMetrics = await _wear.readMetrics();
        }
        final metrics = _latestWearMetrics!;
        final hr = metrics.getMetric(MetricType.hr)?.toDouble() ?? 0.0;
        final hrv = metrics.getMetric(MetricType.hrvSdnn)?.toDouble() ?? 0.0;
        final motion = metrics.metrics['motion']?.toDouble() ?? 0.0;

        print(
            '📊 [SwipSdkManager] Computing SWIP score - HR: ${hr.toStringAsFixed(1)}, HRV: ${hrv.toStringAsFixed(1)}, Motion: ${motion.toStringAsFixed(2)}');

        // Compute SWIP score
        final swipResult = _swipEngine.computeScore(
          hr: hr,
          hrv: hrv,
          motion: motion,
          emotion: _buildEmotionSnapshot(latestEmotion),
        );

        print(
            '✅ [SwipSdkManager] SWIP score computed: ${swipResult.swipScore.toStringAsFixed(1)} (emotion: ${swipResult.dominantEmotion})');

        // Store and emit score
        _sessionScores.add(swipResult);

        if (_scoreStreamController.isClosed) {
          print(
              '⚠️ [SwipSdkManager] Score stream controller is closed, cannot emit');
        } else {
          _scoreStreamController.add(swipResult);
        }
      } catch (e) {
        print(
            '❌ [SwipSdkManager] Failed to read metrics or compute SWIP score: $e');
      }
    } catch (e) {
      // Error processing emotion updates
    }
  }

  /// Generate RR intervals from HR and HRV metrics (SDNN and/or RMSSD)
  ///
  /// This method creates a realistic sequence of RR intervals that would
  /// produce the observed HRV metrics when calculated from them.
  ///
  /// Algorithm:
  /// 1. Calculate mean RR from HR: meanRR = 60000 / HR
  /// 2. Use SDNN as the target standard deviation
  /// 3. Use RMSSD to add short-term variability (if available)
  /// 4. Generate a sequence with correct statistical properties
  List<double> _generateRRIntervalsFromHRV({
    required double hr,
    double? hrvSdnn,
    double? hrvRmssd,
  }) {
    // Calculate mean RR interval from heart rate
    final meanRR = 60000.0 / hr;

    // Determine target variability
    // Prefer SDNN if available, otherwise estimate from RMSSD
    // RMSSD is typically 0.5-0.7 of SDNN for healthy individuals
    final targetStdDev =
        hrvSdnn ?? (hrvRmssd != null ? hrvRmssd / 0.6 : meanRR * 0.05);

    // Generate ~60 intervals for ~1 minute of data (adjust based on HR)
    // Aim for roughly 1 minute: numIntervals ≈ HR (since HR is beats per minute)
    final numIntervals = (hr * 1.0).round().clamp(30, 120);

    final intervals = <double>[];

    // Generate RR intervals with correct mean and standard deviation
    // Using a simple autoregressive model to create realistic variability
    double currentRR = meanRR;
    final alpha = 0.7; // Autocorrelation coefficient for smooth transitions

    for (int i = 0; i < numIntervals; i++) {
      // Add random variation scaled by target standard deviation
      final randomValue = _getPseudoRandom();
      final randomComponent = (randomValue - 0.5) * 2.0 * targetStdDev;

      // Use autoregressive model: new = α * old + (1-α) * target + noise
      currentRR = alpha * currentRR + (1 - alpha) * meanRR + randomComponent;

      // Add short-term variability if RMSSD is available
      if (hrvRmssd != null && i > 0) {
        // RMSSD captures beat-to-beat differences
        final shortTermRandom = _getPseudoRandom();
        final shortTermVar = (shortTermRandom - 0.5) * hrvRmssd * 0.5;
        currentRR += shortTermVar;
      }

      // Clamp to physiologically valid range (300ms to 2000ms)
      currentRR = currentRR.clamp(300.0, 2000.0);
      intervals.add(currentRR);
    }

    // Post-process: scale the sequence to match the target SDNN exactly
    if (hrvSdnn != null && intervals.length >= 2) {
      final currentMean = intervals.reduce((a, b) => a + b) / intervals.length;
      final currentVariance = intervals
              .map((x) => (x - currentMean) * (x - currentMean))
              .reduce((a, b) => a + b) /
          (intervals.length - 1);
      final currentStdDev = math.sqrt(currentVariance);

      if (currentStdDev > 0.1) {
        // Scale to match target SDNN while preserving mean
        final scaleFactor = targetStdDev / currentStdDev;
        for (int i = 0; i < intervals.length; i++) {
          intervals[i] =
              currentMean + (intervals[i] - currentMean) * scaleFactor;
          intervals[i] = intervals[i].clamp(300.0, 2000.0);
        }
      }
    }

    return intervals;
  }

  /// Simple pseudo-random number generator for deterministic but varied sequences
  /// Uses a linear congruential generator with a seed based on timestamp
  int _randomSeed = DateTime.now().millisecondsSinceEpoch;

  /// Get next pseudo-random number in range [0, 1)
  double _getPseudoRandom() {
    // Linear congruential generator: simple but sufficient for this use case
    _randomSeed = (_randomSeed * 1103515245 + 12345) & 0x7fffffff;
    return _randomSeed / 0x7fffffff; // Normalize to [0, 1)
  }

  /// Stream of SWIP scores (emits ~1 Hz)
  Stream<SwipScoreResult> get scoreStream {
    return _scoreStreamController.stream;
  }

  /// Stream of emotion results
  Stream<EmotionResult> get emotionStream {
    return _emotionStreamController.stream;
  }

  /// Get current SWIP score
  SwipScoreResult? getCurrentScore() {
    return _sessionScores.isNotEmpty ? _sessionScores.last : null;
  }

  /// Get current emotion
  EmotionResult? getCurrentEmotion() {
    return _sessionEmotions.isNotEmpty ? _sessionEmotions.last : null;
  }

  /// Clear session data
  void _clearSession() {
    _sessionScores.clear();
    _sessionEmotions.clear();
    _activeSessionId = null;
    _emotionEngine?.clear();
  }

  /// Dispose resources
  void dispose() {
    _wearSubscription?.cancel();
    _emotionProcessor?.cancel();
    _scoreStreamController.close();
    _emotionStreamController.close();
    _wear.dispose();
  }

  EmotionSnapshot _buildEmotionSnapshot(EmotionResult result) {
    final probabilities = result.probabilities;
    final stressProb = probabilities['Stress'] ??
        probabilities['Stressed'] ??
        probabilities['stress'] ??
        0.0;
    final calmProb = probabilities['Calm'] ??
        probabilities['calm'] ??
        probabilities['Relaxed'] ??
        0.0;
    double arousal = stressProb;
    if (arousal <= 0.0 && probabilities.isNotEmpty) {
      arousal = 1.0 - calmProb;
    }
    if (arousal <= 0.0) {
      arousal = result.confidence;
    }
    arousal = arousal.clamp(0.0, 1.0);

    final state = _mapEmotionState(result.emotion);
    final confidence = result.confidence.clamp(0.0, 1.0);
    final isWarmingUp = probabilities.isEmpty;

    return EmotionSnapshot(
      arousalScore: arousal,
      state: state,
      confidence: confidence,
      isWarmingUp: isWarmingUp,
    );
  }

  String _mapEmotionState(String label) {
    switch (label.toLowerCase()) {
      case 'calm':
      case 'relaxed':
      case 'baseline':
        return 'Calm';
      case 'stress':
      case 'stressed':
      case 'anxious':
        return 'Stress';
      case 'amusement':
      case 'amused':
        return 'Neutral';
      default:
        return 'Neutral';
    }
  }
}

/// Configuration for SWIP SDK
class SwipSdkConfig {
  final SwipConfig swipConfig;
  final EmotionConfig emotionConfig;
  final bool enableLogging;
  final bool enableLocalStorage;
  final String? localStoragePath;

  const SwipSdkConfig({
    SwipConfig? swipConfig,
    EmotionConfig? emotionConfig,
    this.enableLogging = true,
    this.enableLocalStorage = true,
    this.localStoragePath,
  })  : swipConfig = swipConfig ?? const SwipConfig(),
        emotionConfig = emotionConfig ??
            const EmotionConfig(
              modelId: 'extratrees_chest_ecg_w60s5_v1_0',
              window: Duration(seconds: 60),
              step: Duration(seconds: 5),
            );
}
