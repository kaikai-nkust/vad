// vad_iterator.dart

import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'vad_event.dart';

typedef VadEventCallback = void Function(VadEvent event);

class VadIterator {
  bool isDebug = false;
  double positiveSpeechThreshold = 0.5;
  double negativeSpeechThreshold = 0.35;
  int redemptionFrames = 8;
  int frameSamples = 1536;
  int preSpeechPadFrames = 1;
  int minSpeechFrames = 3;
  int sampleRate = 16000;
  bool submitUserSpeechOnPause = false;

  // Internal variables
  bool speaking = false;
  int redemptionCounter = 0;
  int speechPositiveFrameCount = 0;
  int _currentSample = 0; // To track position in samples

  List<Float32List> preSpeechBuffer = [];
  List<Float32List> speechBuffer = [];

  // Model variables
  OrtSessionOptions? _sessionOptions;
  OrtSession? _session;

  // Model states
  static const int _batch = 1;
  var _hide = List.filled(2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
  var _cell = List.filled(2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));

  VadEventCallback? onVadEvent;

  // Buffers and frames
  final List<int> _byteBuffer = [];
  int frameByteCount;

  VadIterator({
    required this.isDebug,
    required this.sampleRate,
    required this.frameSamples,
    required this.positiveSpeechThreshold,
    required this.negativeSpeechThreshold,
    required this.redemptionFrames,
    required this.preSpeechPadFrames,
    required this.minSpeechFrames,
    required this.submitUserSpeechOnPause,
  }) : frameByteCount = frameSamples * 2;

  Future<void> initModel(String modelPath) async {
    try {
      _sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(1)
        ..setIntraOpNumThreads(1)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      final rawAssetFile = await rootBundle.load(modelPath);
      final bytes = rawAssetFile.buffer.asUint8List();
      _session = OrtSession.fromBuffer(bytes, _sessionOptions!);
      if (isDebug) debugPrint('VAD model initialized from $modelPath.');
    } catch (e) {
      debugPrint('VAD model initialization failed: $e');
      onVadEvent?.call(VadEvent(
        type: VadEventType.error,
        timestamp: _getCurrentTimestamp(),
        message: 'VAD model initialization failed: $e',
      ));
    }
  }

  void reset() {
    speaking = false;
    redemptionCounter = 0;
    speechPositiveFrameCount = 0;
    _currentSample = 0;
    preSpeechBuffer.clear();
    speechBuffer.clear();
    _byteBuffer.clear();
    _hide = List.filled(2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
    _cell = List.filled(2, List.filled(_batch, Float32List.fromList(List.filled(64, 0.0))));
  }

  void release() {
    _sessionOptions?.release();
    _sessionOptions = null;
    _session?.release();
    _session = null;
    OrtEnv.instance.release();
  }

  void setVadEventCallback(VadEventCallback callback) {
    onVadEvent = callback;
  }

  Future<void> processAudioData(List<int> data) async {
    _byteBuffer.addAll(data);

    while (_byteBuffer.length >= frameByteCount) {
      final frameBytes = _byteBuffer.sublist(0, frameByteCount);
      _byteBuffer.removeRange(0, frameByteCount);
      final frameData = _convertBytesToFloat32(Uint8List.fromList(frameBytes));
      await _processFrame(Float32List.fromList(frameData));
    }
  }

  Future<void> _processFrame(Float32List data) async {
    if (_session == null) {
      debugPrint('VAD Iterator: Session not initialized.');
      return;
    }

    // Run model inference
    final inputOrt = OrtValueTensor.createTensorWithDataList(data, [_batch, frameSamples]);
    final srOrt = OrtValueTensor.createTensorWithData(sampleRate);
    final hOrt = OrtValueTensor.createTensorWithDataList(_hide);
    final cOrt = OrtValueTensor.createTensorWithDataList(_cell);
    final runOptions = OrtRunOptions();
    final inputs = {'input': inputOrt, 'sr': srOrt, 'h': hOrt, 'c': cOrt};
    final outputs = _session!.run(runOptions, inputs);

    inputOrt.release();
    srOrt.release();
    hOrt.release();
    cOrt.release();
    runOptions.release();

    // Output probability & update h,c recursively
    final speechProb = (outputs[0]?.value as List<List<double>>)[0][0];
    _hide = (outputs[1]?.value as List<List<List<double>>>)
        .map((e) => e.map((e) => Float32List.fromList(e)).toList())
        .toList();
    _cell = (outputs[2]?.value as List<List<List<double>>>)
        .map((e) => e.map((e) => Float32List.fromList(e)).toList())
        .toList();
    for (var element in outputs) {
      element?.release();
    }

    _currentSample += frameSamples;

    // Handle state transitions
    if (speechProb >= positiveSpeechThreshold) {
      // Speech-positive frame
      if (!speaking) {
        speaking = true;
        onVadEvent?.call(VadEvent(
          type: VadEventType.start,
          timestamp: _getCurrentTimestamp(),
          message: 'Speech started at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        ));
        speechBuffer.addAll(preSpeechBuffer);
        preSpeechBuffer.clear();
      }
      redemptionCounter = 0;
      speechBuffer.add(data);
      speechPositiveFrameCount++;
    } else if (speechProb < negativeSpeechThreshold) {
      // Speech-negative frame
      if (speaking) {
        if (++redemptionCounter >= redemptionFrames) {
          // End of speech
          speaking = false;
          redemptionCounter = 0;

          if (speechPositiveFrameCount >= minSpeechFrames) {
            // Valid speech segment
            onVadEvent?.call(VadEvent(
              type: VadEventType.end,
              timestamp: _getCurrentTimestamp(),
              message: 'Speech ended at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
              audioData: _combineSpeechBuffer(),
            ));
          } else {
            // Misfire
            onVadEvent?.call(VadEvent(
              type: VadEventType.misfire,
              timestamp: _getCurrentTimestamp(),
              message: 'Misfire detected at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
            ));
          }
          // Reset counters and buffers
          speechPositiveFrameCount = 0;
          speechBuffer.clear();
        } else {
          speechBuffer.add(data);
        }
      } else {
        // Not speaking, maintain pre-speech buffer
        _addToPreSpeechBuffer(data);
      }
    } else {
      // Probability between thresholds, ignore frame for state transitions
      if (speaking) {
        speechBuffer.add(data);
        redemptionCounter = 0;
      } else {
        _addToPreSpeechBuffer(data);
      }
    }
  }

  void forceEndSpeech() {
    if (speaking && speechPositiveFrameCount >= minSpeechFrames) {
      if (isDebug) debugPrint('VAD Iterator: Forcing speech end.');
      onVadEvent?.call(VadEvent(
        type: VadEventType.end,
        timestamp: _getCurrentTimestamp(),
        message: 'Speech forcefully ended at ${_getCurrentTimestamp().toStringAsFixed(3)}s',
        audioData: _combineSpeechBuffer(),
      ));
      // Reset state
      speaking = false;
      redemptionCounter = 0;
      speechPositiveFrameCount = 0;
      speechBuffer.clear();
      preSpeechBuffer.clear();
    }
  }

  void _addToPreSpeechBuffer(Float32List data) {
    preSpeechBuffer.add(data);
    while (preSpeechBuffer.length > preSpeechPadFrames) {
      preSpeechBuffer.removeAt(0);
    }
  }

  double _getCurrentTimestamp() {
    return _currentSample / sampleRate;
  }

  Uint8List _combineSpeechBuffer() {
    final int totalLength = speechBuffer.fold(0, (sum, frame) => sum + frame.length);
    final Float32List combined = Float32List(totalLength);
    int offset = 0;
    for (var frame in speechBuffer) {
      combined.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }
    final int16Data = Int16List.fromList(
        combined.map((e) => (e * 32767).clamp(-32768, 32767).toInt()).toList());
    final Uint8List audioData = Uint8List.view(int16Data.buffer);
    return audioData;
  }

  List<double> _convertBytesToFloat32(Uint8List data) {
    final buffer = data.buffer;
    final int16List = Int16List.view(buffer);
    return int16List.map((e) => e / 32768.0).toList();
  }
}