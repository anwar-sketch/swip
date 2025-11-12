# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-XX

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

