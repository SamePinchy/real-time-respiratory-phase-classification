import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'viterbi_decoder.dart';

// ── Breathing phase enum ──────────────────────────────────────────────────────

enum BreathingPhase {
  inhale,
  exhale,
  retentionInhale,
  retentionExhale,
  unknown;

  static BreathingPhase fromIndex(int index) {
    switch (index) {
      case 0:  return inhale;
      case 1:  return exhale;
      case 2:  return retentionInhale;
      case 3:  return retentionExhale;
      default: return unknown;
    }
  }

  String get displayName {
    switch (this) {
      case inhale:          return 'Wdech';
      case exhale:          return 'Wydech';
      case retentionInhale: return 'Zatrzymanie (wdech)';
      case retentionExhale: return 'Zatrzymanie (wydech)';
      case unknown:         return '—';
    }
  }

  Color get color {
    switch (this) {
      case inhale:          return const Color(0xFF4FC3F7); // light blue
      case exhale:          return const Color(0xFFEF9A9A); // light red
      case retentionInhale: return const Color(0xFFA5D6A7); // light green
      case retentionExhale: return const Color(0xFFFFE082); // light yellow
      case unknown:         return Colors.grey;
    }
  }

  IconData get icon {
    switch (this) {
      case inhale:          return Icons.arrow_upward;
      case exhale:          return Icons.arrow_downward;
      case retentionInhale: return Icons.pause_circle;
      case retentionExhale: return Icons.pause_circle_outline;
      case unknown:         return Icons.help_outline;
    }
  }
}

// ── Classifier ────────────────────────────────────────────────────────────────

class BreathingClassifier {
  // CNN input window size (must match train_model.py WINDOW = 30)
  static const int cnnWindow = 30;

  // How many recent CNN outputs to feed into Viterbi (3 seconds of context)
  static const int viterbiWindow = 30;

  int _lastInferUs = 0;
  OrtSession? _session;

  // Circular buffers
  final List<double>       _samples  = [];   // raw stretch % values
  final List<List<double>> _logProbs = [];   // log-prob vectors per frame

  BreathingPhase _currentPhase = BreathingPhase.unknown;
  BreathingPhase get currentPhase => _currentPhase;

  bool get isReady => _session != null;

  // ── Initialise ────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    try {
      OrtEnv.instance.init();
      final bytes = await _loadAssetBytes('assets/breathing_model.onnx');
      final opts  = OrtSessionOptions();
      _session    = OrtSession.fromBuffer(bytes, opts);
    } catch (e) {
      debugPrint('[BreathingClassifier] init error: $e');
    }
  }

  Future<Uint8List> _loadAssetBytes(String path) async {
    final data = await rootBundle.load(path);
    return data.buffer.asUint8List();
  }

  // ── Feed one new sample ───────────────────────────────────────────────────
  /// Call this every time a new [stretchPercent] value (0-100 %) arrives.
  /// Updates [currentPhase] after each call once the buffer is filled.
  void addSample(double stretchPercent) {
    if (_session == null) return;
    final swTotal = Stopwatch()..start();

    _samples.add(stretchPercent);
    if (_samples.length > cnnWindow * 3) _samples.removeAt(0);

    if (_samples.length < cnnWindow) return;

    final window     = _samples.sublist(_samples.length - cnnWindow);
    final normalized = _normalizeWindow(window);
    final logProb    = _runInference(normalized);
    if (logProb == null) return;

    _logProbs.add(logProb);
    if (_logProbs.length > viterbiWindow) _logProbs.removeAt(0);

    if (_logProbs.length < 3) return;

    final path     = viterbi(_logProbs);
    final filtered = minDurationFilter(path);
    _currentPhase  = BreathingPhase.fromIndex(filtered.last);

    swTotal.stop();
    debugPrint('[PERF] $_lastInferUs ${swTotal.elapsedMicroseconds}');
  }

  // ── Convert stretch % [0, 100] → model input [-1, 1] ─────────────────────
  // Affine map anchored on the resting level of the training set:
  //   20 %  (rest) → -0.956
  //   100 % (peak) → +1.000
  static const double _inputScale  = 0.024454;
  static const double _inputOffset = -1.445444;

  List<double> _normalizeWindow(List<double> window) {
    return window
        .map((v) => (v * _inputScale + _inputOffset).clamp(-1.0, 1.0))
        .toList();
  }

  // ── Run ONNX inference ────────────────────────────────────────────────────
  List<double>? _runInference(List<double> normalized) {
    final sw = Stopwatch()..start();
    try {
      final input  = Float32List.fromList(normalized);
      final tensor = OrtValueTensor.createTensorWithDataList(input, [1, cnnWindow]);

      final runOpts = OrtRunOptions();
      final outputs = _session!.run(runOpts, {'window': tensor});

      final logits = (outputs[0]!.value as List<List<double>>)[0];

      for (final o in outputs) { o?.release(); }

      tensor.release();
      runOpts.release();

      final result = logSoftmax(logits);
      sw.stop();
      _lastInferUs = sw.elapsedMicroseconds;
      return result;
    } catch (e) {
      debugPrint('[BreathingClassifier] inference error: $e');
      return null;
    }
  }

  // ── Reset (e.g. on new session) ───────────────────────────────────────────
  void reset() {
    _samples.clear();
    _logProbs.clear();
    _currentPhase = BreathingPhase.unknown;
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
