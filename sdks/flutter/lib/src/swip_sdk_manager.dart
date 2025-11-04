import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;
import 'package:swip_core/swip.dart';
import 'package:synheart_wear/synheart_wear.dart';
import 'package:synheart_emotion/synheart_emotion.dart';
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
  final EmotionEngine _emotionEngine;
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
  StreamSubscription<WearMetrics>? _hrvSubscription;
  Timer? _emotionProcessor;

  // Configuration
  final SwipSdkConfig config;

  // Session data
  final List<SwipScoreResult> _sessionScores = [];
  final List<EmotionResult> _sessionEmotions = [];

  SwipSdkManager({
    required this.config,
    SynheartWear? wear,
    EmotionEngine? emotionEngine,
    SwipEngine? swipEngine,
  })  : _wear = wear ?? SynheartWear(),
        _emotionEngine = emotionEngine ??
            EmotionEngine.fromPretrained(
              config.emotionConfig,
              model: LinearSvmModel.fromArrays(
                modelId: 'wesad_emotion_v1_0',
                version: '1.0',
                labels: ['Amused', 'Calm', 'Stressed'],
                featureNames: ['hr_mean', 'sdnn', 'rmssd'],
                weights: [
                  [0.12, 0.5, 0.3], // Amused: higher HR, higher HRV
                  [-0.21, -0.4, -0.3], // Calm: lower HR, lower HRV
                  [
                    0.02,
                    0.2,
                    0.1
                  ], // Stressed: slightly higher HR, moderate HRV
                ],
                biases: [-0.2, 0.3, 0.1],
                mu: {
                  'hr_mean': 72.5,
                  'sdnn': 45.3,
                  'rmssd': 32.1,
                },
                sigma: {
                  'hr_mean': 12.0,
                  'sdnn': 18.7,
                  'rmssd': 12.4,
                },
              ),
              onLog: (level, message, {context}) {
                print('[SWIP][EMO][$level] $message');
              },
            ),
        _swipEngine = swipEngine ??
            SwipEngineFactory.createDefault(
              config: config.swipConfig,
              onLog: (level, message, {context}) {
                print('[$level] $message');
              },
            );

  /// Initialize the SDK
  Future<void> initialize() async {
    if (_initialized) {
      _log('info', 'SWIP SDK already initialized');
      return;
    }

    try {
      _log('info', 'Initializing SWIP SDK...');

      // Initialize wearable SDK
      _log('debug', 'Initializing SynheartWear...');
      await _wear.initialize();
      _isWearInitialized = true;
      _log('debug', 'SynheartWear initialized successfully');

      // Request permissions for health data
      _log('debug', 'Requesting health data permissions...');
      await _wear.requestPermissions();
      _log('debug', 'Permissions requested');

      _initialized = true;
      _log('info', 'SWIP SDK initialized successfully');
    } catch (e, stackTrace) {
      _log('error', 'Failed to initialize: $e');
      _log('error', 'Stack trace: $stackTrace');
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
      // Initialize wearable SDK if not already initialized
      if (!_isWearInitialized) {
        await _wear.initialize();
      }

      // Subscribe to HR stream - this provides HR data regularly and may include HRV
      // We use this as the primary source since it emits more frequently
      _log('debug', 'Subscribing to HR stream...');
      _wearSubscription =
          _wear.streamHR(interval: const Duration(seconds: 2)).listen(
        (metrics) {
          _log('debug',
              'Received HR stream metrics - processing for emotion engine');
          // Handle HR stream metrics - this is the primary data source
          _handleWearMetrics(metrics);
        },
        onError: (error) {
          _log('error', 'Error in HR stream: $error');
        },
        onDone: () {
          _log('warn', 'HR stream closed');
        },
      );
      _log('debug', 'HR stream subscription active');

      // Subscribe to HRV stream for HRV data when available
      // This supplements the HR stream with HRV-specific data
      _log('debug', 'Subscribing to HRV stream...');
      _hrvSubscription =
          _wear.streamHRV(windowSize: const Duration(seconds: 5)).listen(
        (metrics) {
          _log('debug',
              'Received HRV stream metrics - will use if HRV data present');
          // Also handle HRV stream metrics - they may have better HRV data
          _handleWearMetrics(metrics);
        },
        onError: (error) {
          _log('error', 'Error in HRV stream: $error');
        },
        onDone: () {
          _log('warn', 'HRV stream closed');
        },
      );
      _log('debug', 'HRV stream subscription active');

      // Start emotion processing timer (1 Hz)
      _log('debug', 'Starting emotion processing timer (1 Hz)...');
      _emotionProcessor = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _processEmotionUpdates(),
      );
      _log('debug', 'Emotion processing timer started');

      _isRunning = true;
      _log('info', 'Session started: $_activeSessionId');

      return _activeSessionId!;
    } catch (e) {
      _log('error', 'Failed to start session: $e');
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
      // Cancel subscriptions
      await _wearSubscription?.cancel();
      _wearSubscription = null;
      await _hrvSubscription?.cancel();
      _hrvSubscription = null;

      // Stop timer
      _emotionProcessor?.cancel();
      _emotionProcessor = null;

      // Metrics subscription will stop automatically when disposed

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

      _isRunning = false;
      _log('info', 'Session stopped: $_activeSessionId');

      return results;
    } catch (e) {
      _log('error', 'Failed to stop session: $e');
      throw SessionError('Failed to stop session: $e');
    }
  }

  /// Handle incoming wearable metrics from either HR or HRV stream
  void _handleWearMetrics(WearMetrics metrics) {
    _log('debug', 'Received wear metrics at ${metrics.timestamp}');
    log('_handleWearMetrics called with metrics from source: ${metrics.source}');

    // Extract HR and HRV
    final hr = metrics.getMetric(MetricType.hr)?.toDouble();
    final hrvSdnn = metrics.getMetric(MetricType.hrvSdnn)?.toDouble();
    final hrvRmssd = metrics.getMetric(MetricType.hrvRmssd)?.toDouble();
    final motion = metrics.metrics['motion']?.toDouble() ?? 0.0;

    log('Metrics: HR=$hr, HRV_SDNN=$hrvSdnn, HRV_RMSSD=$hrvRmssd, Motion=$motion, RR=${metrics.rrMs?.length ?? 0} intervals');

    if (hr == null) {
      _log('warn', 'Missing HR data, skipping emotion engine update');
      return;
    }

    // Use real RR intervals if available, otherwise generate synthetic ones
    List<double> rrIntervals;
    if (metrics.rrMs != null && metrics.rrMs!.isNotEmpty) {
      rrIntervals = metrics.rrMs!;
      _log('debug',
          'Using real RR intervals from metrics: ${rrIntervals.length} intervals');
    } else {
      // Generate synthetic RR intervals from HR and HRV data (or just HR with default variability)
      print(
          'Generating synthetic RR intervals from HR${hrvSdnn != null || hrvRmssd != null ? " and HRV" : ""} data');
      rrIntervals = _generateRRIntervalsFromHRV(
        hr: hr,
        hrvSdnn: hrvSdnn,
        hrvRmssd: hrvRmssd,
      );
      _log('debug',
          'Generated synthetic RR intervals: ${rrIntervals.length} intervals from HR=$hr, SDNN=${hrvSdnn ?? "N/A"}, RMSSD=${hrvRmssd ?? "N/A"}');
    }

    _log('debug',
        'Pushing to emotion engine: HR=$hr, RR intervals count=${rrIntervals.length}');

    // Push to emotion engine
    try {
      // Use current time for timestamp - emotion engine needs real-time window calculations
      // The metrics.timestamp may be when data was originally recorded (could be old),
      // but for the sliding window, we need when we're processing it now
      final now = DateTime.now().toUtc();

      _log('debug',
          'Timestamp - Metrics: ${metrics.timestamp}, Using: $now (difference: ${now.difference(metrics.timestamp.isUtc ? metrics.timestamp : metrics.timestamp.toUtc()).inSeconds}s)');

      _emotionEngine.push(
        hr: hr,
        rrIntervalsMs: rrIntervals,
        timestamp: now,
        motion: {'magnitude': motion},
      );
      _log('debug', 'Data pushed to emotion engine successfully');

      // Log buffer stats after push
      final bufferStats = _emotionEngine.getBufferStats();
      _log('debug',
          'After push - Buffer: ${bufferStats['count']} points, ${bufferStats['rr_count']} RR intervals, ${bufferStats['duration_ms']}ms');
    } catch (e, stackTrace) {
      _log('error', 'Error pushing to emotion engine: $e');
      _log('debug', 'Stack trace: $stackTrace');
    }
  }

  /// Process emotion updates from the emotion engine
  void _processEmotionUpdates() async {
    _log('debug', 'Processing emotion updates...');

    try {
      // Log buffer stats for debugging
      final bufferStats = _emotionEngine.getBufferStats();
      final bufferCount = bufferStats['count'] as int;
      final rrCount = bufferStats['rr_count'] as int;
      final durationMs = bufferStats['duration_ms'] as int;

      _log('debug',
          'Emotion engine buffer: $bufferCount data points, $rrCount RR intervals, ${durationMs}ms duration');

      // Log emotion engine config
      _log('debug',
          'Emotion engine config: window=${_emotionEngine.config.window.inSeconds}s, step=${_emotionEngine.config.step.inSeconds}s, minRrCount=${_emotionEngine.config.minRrCount}');

      // Check if we have enough data
      if (bufferCount < 2) {
        _log('debug',
            'Not enough data points in buffer (need at least 2, have $bufferCount)');
      }
      if (rrCount < _emotionEngine.config.minRrCount) {
        _log('debug',
            'Not enough RR intervals (need ${_emotionEngine.config.minRrCount}, have $rrCount)');
      }
      if (durationMs < _emotionEngine.config.window.inMilliseconds) {
        _log('debug',
            'Buffer duration insufficient (need ${_emotionEngine.config.window.inMilliseconds}ms, have ${durationMs}ms)');
      }

      final emotionResults = await _emotionEngine.consumeReady();

      _log('debug',
          'Emotion engine returned ${emotionResults.length} ready results');

      if (emotionResults.isEmpty) {
        // Check for common reasons why results might be empty
        final reasons = <String>[];
        if (bufferCount < 2) {
          reasons.add('insufficient data points (have $bufferCount, need ≥2)');
        }
        if (rrCount < _emotionEngine.config.minRrCount) {
          reasons.add(
              'insufficient RR intervals (have $rrCount, need ≥${_emotionEngine.config.minRrCount})');
        }
        if (durationMs < _emotionEngine.config.window.inMilliseconds) {
          reasons.add(
              'insufficient window duration (have ${durationMs}ms, need ≥${_emotionEngine.config.window.inMilliseconds}ms)');
        }

        _log('warn',
            'No emotion results ready yet. Buffer: $bufferCount points, $rrCount RR intervals, ${durationMs}ms duration. Issues: ${reasons.isEmpty ? "may need more time for step interval or model may be null" : reasons.join(", ")}');
        return;
      }

      // Get latest emotion result
      final latestEmotion = emotionResults.last;
      _log('info',
          'Emotion detected: ${latestEmotion.emotion} (confidence: ${(latestEmotion.confidence * 100).toStringAsFixed(1)}%)');
      _log('debug', 'Emotion probabilities: ${latestEmotion.probabilities}');

      _sessionEmotions.add(latestEmotion);
      _log('debug',
          'Added emotion to session (total: ${_sessionEmotions.length})');

      // Emit emotion stream
      if (_emotionStreamController.isClosed) {
        _log('error', 'Emotion stream controller is closed, cannot emit');
        return;
      }

      _emotionStreamController.add(latestEmotion);
      _log('debug', 'Emotion result emitted to stream');

      // Get current physiological data for SWIP computation
      try {
        final lastMetrics = await _wear.readMetrics();
        final hr = lastMetrics.getMetric(MetricType.hr)?.toDouble() ?? 0.0;
        final hrv =
            lastMetrics.getMetric(MetricType.hrvSdnn)?.toDouble() ?? 0.0;
        final motion = lastMetrics.metrics['motion']?.toDouble() ?? 0.0;

        _log('debug',
            'Computing SWIP score with: HR=$hr, HRV=$hrv, Motion=$motion');

        // Compute SWIP score
        final swipResult = _swipEngine.computeScore(
          hr: hr,
          hrv: hrv,
          motion: motion,
          emotionProbabilities: latestEmotion.probabilities,
        );

        // Store and emit score
        _sessionScores.add(swipResult);
        _scoreStreamController.add(swipResult);

        _log('info',
            'SWIP Score: ${swipResult.swipScore.toStringAsFixed(1)} (confidence: ${(swipResult.confidence * 100).toStringAsFixed(1)}%)');
      } catch (e, stackTrace) {
        _log('warn', 'Failed to read metrics or compute SWIP score: $e');
        _log('debug', 'Stack trace: $stackTrace');
      }
    } catch (e, stackTrace) {
      _log('error', 'Error processing emotion updates: $e');
      _log('error', 'Stack trace: $stackTrace');
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
    _log('debug',
        'scoreStream accessed (listeners: ${_scoreStreamController.hasListener})');
    return _scoreStreamController.stream;
  }

  /// Stream of emotion results
  Stream<EmotionResult> get emotionStream {
    _log('debug',
        'emotionStream accessed (listeners: ${_emotionStreamController.hasListener})');
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
    _emotionEngine.clear();
  }

  /// Dispose resources
  void dispose() {
    _wearSubscription?.cancel();
    _hrvSubscription?.cancel();
    _emotionProcessor?.cancel();
    _scoreStreamController.close();
    _emotionStreamController.close();
    _wear.dispose();
  }

  /// Log message
  void _log(String level, String message) {
    if (config.enableLogging) {
      print('[SWIP SDK] [$level] $message');
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
        emotionConfig = emotionConfig ?? const EmotionConfig();
}
