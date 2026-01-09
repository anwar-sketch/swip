# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0+7] - 2025-01-09

### Fixed
- **ONNX Inference Error**: Fixed `RangeError (length): Invalid value: Only valid value is 0: 1` error in emotion inference
  - Updated to use `ExtraTrees_60_5_nozipmap.onnx` model (same as synheart-poc-dart)
  - The nozipmap model outputs probabilities directly without ZipMap wrapper, fixing output parsing issues
  - Model ID is now automatically read from loaded model's metadata for consistency

### Changed
- **Model Files**: Updated to use nozipmap ONNX model format
  - Added `ExtraTrees_60_5_nozipmap.onnx` and metadata to SDK assets
  - Model now uses binary classification (Baseline vs Stress) instead of 3-class
  - Model ID: `extratrees_chest_ecg_w60s5_binary_v1_0`

### Added
- **Example App**: Added `SwipController` to example app demonstrating proper SDK integration
  - Shows real-time SWIP scores and emotions
  - Includes session management and history
  - Demonstrates storage integration

### Improved
- Model loading now uses model's own metadata for modelId, ensuring consistency

## [1.0.0+6] - 2025-01-09

### Fixed
- **ONNX Inference Error**: Fixed `RangeError (length): Invalid value: Only valid value is 0: 1` error in emotion inference
  - Updated to use `ExtraTrees_60_5_nozipmap.onnx` model (same as synheart-poc-dart)
  - The nozipmap model outputs probabilities directly without ZipMap wrapper, fixing output parsing issues
  - Model ID is now automatically read from loaded model's metadata for consistency
- **Permission Handling**: Fixed redundant permission requests that prevented Health Connect UI from opening correctly on Android
- **Initialization Flow**: Improved SDK initialization to follow best practices from synheart-poc-dart
  - Now calls `initialize()` first (matching synheart-poc-dart pattern), then checks for existing permissions
  - Gracefully handles cases where Health Connect is not yet installed
  - Re-initializes wearable SDK after permissions are granted
- **Android 14+ Compatibility**: Fixed "Permission launcher not found" error by requiring `MainActivity` to extend `FlutterFragmentActivity` instead of `FlutterActivity` (see example app)

### Changed
- **Model Files**: Updated to use nozipmap ONNX model format
  - Added `ExtraTrees_60_5_nozipmap.onnx` and metadata to SDK assets
  - Model now uses binary classification (Baseline vs Stress) instead of 3-class
  - Model ID: `extratrees_chest_ecg_w60s5_binary_v1_0`
- **Permission Request Pattern**: Updated to explicitly request platform-specific permissions
  - Android: Requests `heartRate`, `heartRateVariability` (RMSSD), `steps`, `calories` (excludes `distance` as Health Connect doesn't support it)
  - iOS: Requests all types including `distance` (HealthKit supports all)
- **Error Handling**: Better error handling for Health Connect availability issues
  - SDK can now work even if Health Connect is installed after initial initialization attempt

### Added
- **Example App**: Added `SwipController` to example app demonstrating proper SDK integration
  - Shows real-time SWIP scores and emotions
  - Includes session management and history
  - Demonstrates storage integration

### Improved
- Health Connect permissions screen now opens correctly when permissions are requested
- Removed duplicate permission requests that were causing initialization issues
- Better state management for wearable SDK initialization
- Model loading now uses model's own metadata for modelId, ensuring consistency

## [1.0.0+4] - 2025-12-XX

### Added
- New version of synheart_wear with health connect for android

## [1.0.0+3] - 2025-11-XX

### Fixed
- Removed nested lib/packages/swip_core directory
- Fixed undefined exports (EmotionRecognitionConfig, EmotionState)
- Added version constraint to synheart_wear dependency

## [1.0.0] - 2025-11-XX

### Added
- Initial release of SWIP Flutter SDK
- SWIP SDK Manager for session management
- Integration with synheart_wear for sensor data collection
- Integration with synheart_emotion for emotion recognition
- Integration with swip_core for SWIP score computation
- Consent management system
- Local storage and sync capabilities
- Legacy ML components (feature extraction, SVM predictor, emotion recognition)

### Fixed
- Removed nested lib/packages/swip_core directory
- Fixed undefined exports (EmotionRecognitionConfig, EmotionState)
- Added version constraint to synheart_wear dependency

