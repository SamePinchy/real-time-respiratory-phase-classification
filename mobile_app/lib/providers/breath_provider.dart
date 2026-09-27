import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/breath_data_model.dart';
import '../services/ble_service.dart';
import '../services/mock_data_service.dart';
import '../services/breathing_classifier.dart';
import '../services/cycle_detector.dart';

class BreathProvider extends ChangeNotifier {
  final BLEService _bleService = BLEService();
  final MockDataService _mockService = MockDataService();
  final BreathingClassifier _classifier = BreathingClassifier();
  
  // Getter do BLEService (dla ustawień)
  BLEService get bleService => _bleService;
  
  // Tryb testowy
  bool _isTestMode = false;
  bool get isTestMode => _isTestMode;
  
  BreathSession? _currentSession;
  final List<BreathData>         _realtimeBuffer = [];
  final List<BreathingPhase>     _phaseBuffer    = [];

  // Cached breath rate — recomputed only on each new inhale onset
  double _cachedBreathRate = 0;
  
  // ZMIENIONE: Zwiększony buffer dla dłuższych nagrań
  // 6000 punktów = 10 minut przy 10Hz
  // Jeśli chcesz więcej, zwiększ tę wartość
  static const int maxBufferSize = 6000;
  
  StreamSubscription? _dataSubscription;
  StreamSubscription? _connectionSubscription;
  
  bool _isConnected = false;
  bool _isRecording = false;
  
  // Gettery
  bool get isConnected => _isConnected;
  bool get isRecording => _isRecording;
  bool get isReconnecting => _bleService.isReconnecting;
  List<BreathData>     get realtimeData   => _realtimeBuffer;
  List<BreathingPhase> get realtimePhases => _phaseBuffer;
  BreathSession? get currentSession => _currentSession;
  
  /// Breaths per minute — updated once per detected inhale onset (not every
  /// sample), so the displayed value is stable between breath cycles.
  double get currentBreathRate => _cachedBreathRate;

  /// Recompute [_cachedBreathRate] from accepted cycle starts in the last 60 s.
  /// Cycle starts are detected over the whole buffer with the shared rule
  /// from cycle_detector.dart, so the rate matches the lines on the chart.
  void _recomputeBreathRate() {
    final n = _phaseBuffer.length < _realtimeBuffer.length
        ? _phaseBuffer.length
        : _realtimeBuffer.length;
    if (n < 2) {
      _cachedBreathRate = 0;
      return;
    }

    const int windowSeconds = 60;
    final lastTs = _realtimeBuffer[n - 1].timestamp;
    final windowCutoff =
        lastTs.subtract(const Duration(seconds: windowSeconds));

    int startIdx = 0;
    for (int i = n - 1; i > 0; i--) {
      if (_realtimeBuffer[i].timestamp.isBefore(windowCutoff)) {
        startIdx = i + 1;
        break;
      }
    }

    final windowDuration =
        lastTs.difference(_realtimeBuffer[startIdx].timestamp).inMilliseconds /
            1000.0;
    if (windowDuration < 5) {
      _cachedBreathRate = 0;
      return;
    }

    final starts = detectCycleStarts(
      length: n,
      valueAt: (i) => _realtimeBuffer[i].stretch,
      isInhaleAt: (i) => _phaseBuffer[i] == BreathingPhase.inhale,
    );
    final breaths = starts.where((i) => i >= startIdx).length;

    _cachedBreathRate = breaths == 0 ? 0 : breaths / windowDuration * 60;
  }

  BreathingPhase get currentPhase => _classifier.currentPhase;
  bool get classifierReady => _classifier.isReady;

  // Y-bounds for the chart
  double? _yMin;
  double? _yMax;
  double? get chartYMin => _yMin;
  double? get chartYMax => _yMax;

  BreathProvider() {
    _classifier.initialize();
    _initializeListeners();
  }

  void _initializeListeners() {
    // Nasłuchuj statusu połączenia - BLE
    _connectionSubscription = _bleService.connectionStream.listen((connected) {
      if (!_isTestMode) {
        _isConnected = connected;
        if (!connected) {
          stopRecording();
        }
        notifyListeners();
      }
    });

    // Nasłuchuj statusu połączenia - Mock
    _mockService.connectionStream.listen((connected) {
      if (_isTestMode) {
        _isConnected = connected;
        if (!connected) {
          stopRecording();
        }
        notifyListeners();
      }
    });

    // Nasłuchuj przychodzących danych - BLE
    _dataSubscription = _bleService.dataStream.listen((data) {
      if (_isRecording && !_isTestMode) {
        _addDataPoint(data);
      }
    });

    // Nasłuchuj przychodzących danych - Mock
    _mockService.dataStream.listen((data) {
      if (_isRecording && _isTestMode) {
        _addDataPoint(data);
      }
    });
  }

  void _addDataPoint(BreathData data) {
    // Dodaj do bufora czasu rzeczywistego
    _realtimeBuffer.add(data);

    // ZMIENIONE: Utrzymuj maksymalny rozmiar bufora
    // Tylko dla realtimeBuffer - sesja zachowuje wszystkie dane
    if (_realtimeBuffer.length > maxBufferSize) {
      _realtimeBuffer.removeAt(0);
    }

    // Dodaj do bieżącej sesji (WSZYSTKIE dane, bez limitu)
    if (_currentSession != null) {
      _currentSession!.data.add(data);
      // Placeholder — zostanie nadpisany przez back-fill poniżej
      _currentSession!.phaseIndices.add(BreathingPhase.unknown.index);
    }

    // Y-bounds — BLE only: expand range as new extremes arrive
    if (!_isTestMode) {
      if (_yMin == null || data.stretch < _yMin!) _yMin = data.stretch;
      if (_yMax == null || data.stretch > _yMax!) _yMax = data.stretch;
    }

    // Klasyfikator oddechu
    _classifier.addSample(data.stretch);

    // Center-label alignment: the model was trained with the label assigned to
    // the CENTER of the 30-sample window (sample n-15, not sample n).
    // Add an unknown placeholder for the current sample, then back-fill the
    // correct position (15 steps ago) with the classifier's output.
    _phaseBuffer.add(BreathingPhase.unknown);
    if (_phaseBuffer.length > maxBufferSize) _phaseBuffer.removeAt(0);

    const int halfWindow = 15; // cnnWindow ~/ 2
    final targetIdx = _phaseBuffer.length - 1 - halfWindow;
    if (targetIdx >= 0) {
      final prevPhase = _phaseBuffer[targetIdx];
      _phaseBuffer[targetIdx] = _classifier.currentPhase;

      // Mirror back-fill into session storage (1:1 with session.data)
      if (_currentSession != null) {
        final sessionTargetIdx =
            _currentSession!.phaseIndices.length - 1 - halfWindow;
        if (sessionTargetIdx >= 0) {
          _currentSession!.phaseIndices[sessionTargetIdx] =
              _classifier.currentPhase.index;
        }
      }

      // Recompute breath rate only on inhale onset (once per cycle)
      if (_classifier.currentPhase == BreathingPhase.inhale &&
          prevPhase != BreathingPhase.inhale) {
        _recomputeBreathRate();
      }
    }

    notifyListeners();
  }

  Future<void> connectToDevice(dynamic device) async {
    try {
      // Polaczenie z prawdziwym pasem zawsze konczy tryb testowy.
      // Wczesniej flaga _isTestMode pozostawala ustawiona po uruchomieniu
      // trybu testowego, przez co ta metoda laczyla sie ponownie z mockiem.
      if (_isTestMode) {
        _mockService.stopGeneratingData();
        await _mockService.disconnect();
        _isTestMode = false;
        _isConnected = false;
        notifyListeners();
      }
      await _bleService.connectToDevice(device);
    } catch (e) {
      print('Connection error: $e');
      rethrow;
    }
  }

  Future<void> connectToMockDevice() async {
    _isTestMode = true;
    notifyListeners();
    await _mockService.connectToMockDevice();
  }

  void setTestMode(bool enabled) {
    _isTestMode = enabled;
    notifyListeners();
  }

  Future<void> disconnect() async {
    stopRecording();
    if (_isTestMode) {
      await _mockService.disconnect();
      // Wyjscie z trybu testowego - kolejne polaczenie domyslnie z pasem
      _isTestMode = false;
      _isConnected = false;
      notifyListeners();
    } else {
      await _bleService.disconnect();
    }
  }

  void startRecording() {
    if (!_isConnected) {
      throw Exception('Device not connected');
    }
    
    _currentSession = BreathSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      startTime: DateTime.now(),
    );
    
    _isRecording = true;
    _cachedBreathRate = 0;
    _realtimeBuffer.clear();
    _phaseBuffer.clear();
    _classifier.reset();

    // Y-bounds: for test mode use precomputed file range,
    // for BLE start fresh (will expand as data arrives)
    if (_isTestMode) {
      _yMin = _mockService.fileYMin;
      _yMax = _mockService.fileYMax;
    } else {
      _yMin = null;
      _yMax = null;
    }

    // Uruchom generowanie danych w trybie testowym
    if (_isTestMode) {
      _mockService.startGeneratingData();
    }
    
    notifyListeners();
  }

  void stopRecording() {
    if (_currentSession != null) {
      _currentSession!.endTime = DateTime.now();
      // Sesja zachowuje WSZYSTKIE dane, bez limitu 1000
      print('📊 Sesja zakończona: ${_currentSession!.data.length} punktów danych');
    }
    
    // Zatrzymaj generowanie danych w trybie testowym
    if (_isTestMode) {
      _mockService.stopGeneratingData();
    }
    
    _isRecording = false;
    notifyListeners();
  }

  List<BreathData> getLastNSeconds(int seconds) {
    if (_realtimeBuffer.isEmpty) return [];
    
    final cutoffTime = DateTime.now().subtract(Duration(seconds: seconds));
    
    return _realtimeBuffer.where((data) {
      return data.timestamp.isAfter(cutoffTime);
    }).toList();
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _connectionSubscription?.cancel();
    _classifier.dispose();
    super.dispose();
  }
}