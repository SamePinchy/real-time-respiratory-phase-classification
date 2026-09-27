import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import '../models/breath_data_model.dart';

class MockDataService {
  static final MockDataService _instance = MockDataService._internal();
  factory MockDataService() => _instance;
  MockDataService._internal();

  Timer? _dataTimer;
  final _dataStreamController = StreamController<BreathData>.broadcast();
  Stream<BreathData> get dataStream => _dataStreamController.stream;

  final _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionStateController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  // ── Dane z pliku testowego ────────────────────────────────────────────────
  List<double> _fileStretchValues = [];
  int    _fileIndex  = 0;
  bool   _fileLoaded = false;
  double fileYMin    = 0.0;
  double fileYMax    = 100.0;

  // Fallback — sinusoida gdy plik nie jest dostępny
  final Random _random = Random();
  double _breathPhase = 0.0;
  static const double _breathRate      = 0.25;
  static const double _baseStretch     = 50.0;
  static const double _stretchAmplitude = 30.0;

  // ── Wczytaj plik assetów ──────────────────────────────────────────────────
  Future<void> _loadTestData() async {
    if (_fileLoaded) return;
    try {
      final text = await rootBundle.loadString(
        'lib/testchart/tens_second_subject.txt',
      );
      final values = <double>[];
      for (final line in text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final parts = trimmed.split(',');
        if (parts.isEmpty) continue;
        final raw = double.tryParse(parts[0].trim());
        if (raw == null) continue;
// Plik: wartości [-1, 1] → skala procentowa aplikacji (spoczynek ≈ 20 %)
        values.add(((raw + 1.445444) / 0.024454).clamp(0.0, 100.0));
      }
      if (values.isNotEmpty) {
        _fileStretchValues = values;
        _fileLoaded = true;
        fileYMin = values.reduce((a, b) => a < b ? a : b);
        fileYMax = values.reduce((a, b) => a > b ? a : b);
        print('[MockDataService] Wczytano ${values.length} próbek '
            '(min=${fileYMin.toStringAsFixed(1)}%, max=${fileYMax.toStringAsFixed(1)}%)');
      }
    } catch (e) {
      print('[MockDataService] Nie można wczytać pliku testowego: $e — używam sinusoidy');
    }
  }

  // ── Połączenie ────────────────────────────────────────────────────────────
  Future<void> connectToMockDevice() async {
    await Future.delayed(const Duration(seconds: 2));
    await _loadTestData();
    _isConnected = true;
    _connectionStateController.add(true);
    print('[MockDataService] Połączono (${_fileLoaded ? "dane z pliku" : "sinusoida"})');
  }

  // ── Generowanie danych ────────────────────────────────────────────────────
  void startGeneratingData() {
    if (!_isConnected || _dataTimer != null) return;
    _fileIndex = 0;

    // ~9.8 Hz — dokładna częstotliwość z pliku treningowego
    _dataTimer = Timer.periodic(const Duration(milliseconds: 102), (_) {
      _generateBreathData();
    });
  }

  void stopGeneratingData() {
    _dataTimer?.cancel();
    _dataTimer = null;
  }

  void _generateBreathData() {
    double stretch;

    if (_fileLoaded && _fileStretchValues.isNotEmpty) {
      // Odtwarzaj plik cyklicznie
      stretch = _fileStretchValues[_fileIndex % _fileStretchValues.length];
      _fileIndex++;
    } else {
      // Fallback: sinusoida
      _breathPhase += _breathRate * 0.102;
      final wave  = sin(_breathPhase * 2 * pi);
      final noise = (_random.nextDouble() - 0.5) * 2.0;
      stretch = (_baseStretch + wave * _stretchAmplitude + noise).clamp(0.0, 100.0);
    }

    _dataStreamController.add(BreathData(
      timestamp: DateTime.now(),
      stretch: stretch,
    ));
  }

  // ── Rozłączenie ───────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    stopGeneratingData();
    _isConnected = false;
    _connectionStateController.add(false);
    _breathPhase = 0.0;
    _fileIndex   = 0;
    print('[MockDataService] Rozłączono');
  }

  void dispose() {
    _dataTimer?.cancel();
    _dataStreamController.close();
    _connectionStateController.close();
  }
}
