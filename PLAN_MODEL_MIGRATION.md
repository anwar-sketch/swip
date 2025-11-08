# Plan: Migrate from `wesad_emotion_v1_0` to `extratrees_wrist_all_v1_0`

## Overview
Switch the SWIP SDK from using the LinearSVM model (`wesad_emotion_v1_0`) to the ONNX ExtraTrees model (`extratrees_wrist_all_v1_0`).

## Current State
- **Model Type**: `LinearSvmModel` (JSON-based, 3 features)
- **Model ID**: `wesad_emotion_v1_0`
- **Features**: `['hr_mean', 'sdnn', 'rmssd']` (3 features)
- **Implementation**: Hardcoded weights/biases in `swip_sdk_manager.dart`
- **Location**: `sdks/flutter/lib/src/swip_sdk_manager.dart` (lines 53-78)

## Target State
- **Model Type**: `OnnxEmotionModel` (ONNX binary, 5 features)
- **Model ID**: `extratrees_wrist_all_v1_0`
- **Features**: `['SDNN', 'RMSSD', 'pNN50', 'Mean_RR', 'HR_mean']` (5 features)
- **Model Files**:
  - ONNX: `assets/ml/extratrees_wrist_all_v1_0.onnx`
  - Metadata: `assets/ml/extratrees_wrist_all_v1_0.meta.json`
- **Location**: Both files exist in `sdks/flutter/assets/ml/` and `sdks/flutter/example/assets/ml/`

## Key Differences

### 1. Model Architecture
- **Current**: Linear SVM with manual weights/biases
- **New**: ExtraTrees ONNX model (requires async inference)

### 2. Feature Requirements
- **Current**: 3 features (hr_mean, sdnn, rmssd)
- **New**: 5 features (SDNN, RMSSD, pNN50, Mean_RR, HR_mean)
  - **New features to compute**:
    - `pNN50`: Percentage of RR intervals differing by >50ms from adjacent interval
    - `Mean_RR`: Mean of all RR intervals in the window

### 3. Feature Extraction
- **Current**: `FeatureExtractor.extractFeatures()` extracts `hr_mean`, `sdnn`, `rmssd`
- **New**: Need to extend feature extraction to compute `pNN50` and `Mean_RR` from RR intervals

### 4. Model Loading
- **Current**: `LinearSvmModel.fromArrays()` with hardcoded parameters
- **New**: `OnnxEmotionModel.loadFromAsset()` with async loading

### 5. Inference
- **Current**: Synchronous `model.predict(features)`
- **New**: Asynchronous `model.predictAsync(features)`

## Implementation Steps

### Step 1: Verify Model Assets
- [ ] Confirm `extratrees_wrist_all_v1_0.onnx` exists in `sdks/flutter/assets/ml/`
- [ ] Confirm `extratrees_wrist_all_v1_0.meta.json` exists in `sdks/flutter/assets/ml/`
- [ ] Verify metadata matches expected schema (5 input features, 3 output classes)

### Step 2: Verify Feature Extraction ✅
- [x] **Feature extraction already supports all 5 features!**
- [x] `FeatureExtractor.extractPnn50()` already exists in `synheart-emotion`
- [x] `FeatureExtractor.extractMeanRr()` already exists in `synheart-emotion`
- [x] `FeatureExtractor.extractFeatures()` already includes `pnn50` and `mean_rr`
- [x] Feature names match model expectations (case-insensitive matching in `OnnxEmotionModel`)

**Note**: No changes needed to feature extraction - it already supports all required features!

### Step 3: Update SDK Manager
- [ ] Replace `LinearSvmModel.fromArrays()` with `OnnxEmotionModel.loadFromAsset()`
- [ ] Update model ID from `'wesad_emotion_v1_0'` to `'extratrees_wrist_all_v1_0'`
- [ ] Make emotion engine initialization async (or use `await` in `initialize()`)
- [ ] Update `_processEmotionResults()` to handle async inference (if needed)

**File**: `sdks/flutter/lib/src/swip_sdk_manager.dart`

**Current Code** (lines 50-82):
```dart
_emotionEngine = emotionEngine ??
    EmotionEngine.fromPretrained(
      config.emotionConfig,
      model: LinearSvmModel.fromArrays(
        modelId: 'wesad_emotion_v1_0',
        // ... hardcoded weights/biases
      ),
      // ...
    ),
```

**Target Code**:
```dart
_emotionEngine = emotionEngine ??
    EmotionEngine.fromPretrained(
      config.emotionConfig,
      model: await OnnxEmotionModel.loadFromAsset(
        modelAssetPath: 'assets/ml/extratrees_wrist_all_v1_0.onnx',
        metaAssetPath: 'assets/ml/extratrees_wrist_all_v1_0.meta.json',
      ),
      // ...
    ),
```

**Note**: This requires making the `SwipSdkManager` constructor async or moving model loading to `initialize()`.

### Step 4: Update EmotionConfig
- [ ] Update `EmotionConfig.modelId` default to `'extratrees_wrist_all_v1_0'` (if applicable)
- [ ] Verify `EmotionConfig` in `SwipSdkConfig` uses correct model ID

### Step 5: Update Example App
- [ ] Verify example app displays `'extratrees_wrist_all_v1_0'` as model ID (already done in `main.dart:106`)
- [ ] Ensure example app's `pubspec.yaml` includes the ONNX model assets
- [ ] Test emotion inference with the new model

### Step 6: Handle Async Inference
- [ ] Check if `EmotionEngine.consumeReady()` already handles async ONNX inference
- [ ] If not, update `_processEmotionResults()` to await async inference
- [ ] Ensure error handling for async operations

### Step 7: Testing
- [ ] Test emotion inference with real HR/RR data
- [ ] Verify all 5 features are computed correctly
- [ ] Verify emotion predictions match expected behavior
- [ ] Check model loading time and inference latency
- [ ] Test with synthetic RR intervals (fallback case)

### Step 8: Update Documentation
- [ ] Update SDK README to reflect new model
- [ ] Update any model references in documentation
- [ ] Update example code snippets

## Technical Considerations

### Feature Extraction Implementation
The `synheart-emotion` package's `FeatureExtractor` currently extracts:
- `hr_mean`: Mean HR from HR values
- `sdnn`: Standard deviation of RR intervals
- `rmssd`: Root mean square of successive differences

For the ExtraTrees model, we need to add:
- `pNN50`: Percentage of RR intervals with >50ms difference
- `Mean_RR`: Mean of RR intervals

**Implementation** (to be added to feature extraction):
```dart
// pNN50 calculation
double extractPnn50(List<double> rrIntervalsMs) {
  if (rrIntervalsMs.length < 2) return 0.0;
  int count = 0;
  for (int i = 1; i < rrIntervalsMs.length; i++) {
    if ((rrIntervalsMs[i] - rrIntervalsMs[i-1]).abs() > 50.0) {
      count++;
    }
  }
  return (count / (rrIntervalsMs.length - 1)) * 100.0;
}

// Mean_RR calculation
double extractMeanRr(List<double> rrIntervalsMs) {
  if (rrIntervalsMs.isEmpty) return 0.0;
  return rrIntervalsMs.reduce((a, b) => a + b) / rrIntervalsMs.length;
}
```

### Async Model Loading
The `OnnxEmotionModel.loadFromAsset()` is async, so we need to:
1. Make `SwipSdkManager.initialize()` async (if not already)
2. Await model loading before creating `EmotionEngine`
3. Or use a factory pattern with async initialization

### Model Compatibility
The `OnnxEmotionModel` in `synheart-emotion` supports:
- Feature name matching (case-insensitive)
- Automatic feature extraction from feature map
- Async inference via `predictAsync()`

The `EmotionEngine` should handle ONNX models automatically if the model implements the required interface.

## Files to Modify

1. **`sdks/flutter/lib/src/swip_sdk_manager.dart`**
   - Replace `LinearSvmModel.fromArrays()` with `OnnxEmotionModel.loadFromAsset()`
   - Update model ID
   - Handle async model loading

2. **Feature Extraction** (if needed in `synheart-emotion` or custom implementation)
   - Add `pNN50` and `Mean_RR` extraction methods
   - Update `extractFeatures()` to include new features

3. **`sdks/flutter/lib/src/swip_sdk_config.dart`** (if exists)
   - Update default `EmotionConfig.modelId`

4. **Example App** (verify)
   - Already displays correct model ID
   - Verify assets are included

## Potential Challenges

1. **Async Model Loading**: May require refactoring `SwipSdkManager` constructor
2. **Feature Extraction**: Need to ensure `pNN50` and `Mean_RR` are computed correctly
3. **Model Availability**: Ensure ONNX model file is included in app bundle
4. **Inference Performance**: ONNX inference may have different latency characteristics
5. **Backward Compatibility**: If other code depends on `LinearSvmModel`, may need compatibility layer

## Success Criteria

- [ ] SDK uses `extratrees_wrist_all_v1_0` model
- [ ] All 5 features are computed correctly
- [ ] Emotion inference works with real and synthetic RR intervals
- [ ] Example app displays correct model ID
- [ ] No regression in emotion inference accuracy
- [ ] Model loads successfully on iOS and Android

