import 'dart:convert';
import 'dart:collection';
import 'package:crypto/crypto.dart';

/// Dane kalibracyjne otrzymane z ESP32
class CalibrationData {
  final double baseline;
  final double min;
  final double max;
  final double calibrationFactor;
  final int timestamp;
  
  CalibrationData({
    required this.baseline,
    required this.min,
    required this.max,
    required this.calibrationFactor,
    required this.timestamp,
  });
  
  factory CalibrationData.fromJson(Map<String, dynamic> json) {
    return CalibrationData(
      baseline: (json['baseline'] as num).toDouble(),
      min: (json['min'] as num).toDouble(),
      max: (json['max'] as num).toDouble(),
      calibrationFactor: (json['calibration_factor'] as num).toDouble(),
      timestamp: json['timestamp'] as int,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'baseline': baseline,
      'min': min,
      'max': max,
      'calibration_factor': calibrationFactor,
      'timestamp': timestamp,
    };
  }
  
  @override
  String toString() {
    return 'CalibrationData(baseline: $baseline, min: $min, max: $max)';
  }
}

/// Pakiet danych z surowymi wartościami
class BLEPacket {
  final int sequenceNumber;  // Numer sekwencyjny pakietu
  final double rawValue;     // Surowa wartość z HX711
  final int timestamp;       // Timestamp z ESP32
  final String checksum;     // MD5 checksum
  
  BLEPacket({
    required this.sequenceNumber,
    required this.rawValue,
    required this.timestamp,
    required this.checksum,
  });

  /// Tworzy pakiet z JSON i weryfikuje checksum
  factory BLEPacket.fromJson(Map<String, dynamic> json) {
    final packet = BLEPacket(
      sequenceNumber: json['seq'] as int,
      rawValue: (json['raw'] as num).toDouble(),
      timestamp: json['ts'] as int,
      checksum: json['checksum'] as String,
    );
    
    if (!packet.verifyChecksum()) {
      String calculated = packet.generateChecksum();
      print('🔐 Expected checksum: ${packet.checksum}');
      print('🔐 Calculated checksum: $calculated');
      throw PacketCorruptedException('Checksum verification failed: expected ${packet.checksum}, got $calculated');
    }
    
    return packet;
  }

  /// Generuje checksum dla danych - MUSI BYĆ IDENTYCZNE Z ESP32!
  String generateChecksum() {
    // WAŻNE: Format MUSI być identyczny z ESP32:
    // ESP32: String(seq) + ":" + String(raw, 3) + ":" + String(timestamp)
    
    // Formatuj liczbę z 3 miejscami po przecinku (jak w ESP32)
    String rawStr = rawValue.toStringAsFixed(3);
    
    final data = '$sequenceNumber:$rawStr:$timestamp';
    
    // Oblicz MD5 i weź pierwsze 8 znaków
    var bytes = utf8.encode(data);
    var digest = md5.convert(bytes);
    return digest.toString().substring(0, 8);
  }

  /// Weryfikuje integralność pakietu
  bool verifyChecksum() {
    return generateChecksum() == checksum;
  }

  Map<String, dynamic> toJson() {
    return {
      'seq': sequenceNumber,
      'raw': rawValue,
      'ts': timestamp,
      'checksum': checksum,
    };
  }

  @override
  String toString() {
    return 'BLEPacket(seq: $sequenceNumber, raw: $rawValue)';
  }
}

/// =============================================================================
/// KOMPENSATOR DRYFU BAZOWEGO (BASELINE DRIFT COMPENSATOR)
/// =============================================================================
/// 
/// Ten kompensator automatycznie wykrywa i koryguje dryf tensometrów,
/// utrzymując wartość spoczynkową (pomiędzy wdechami) na poziomie targetBaseline (20%).
/// 
/// Algorytm:
/// 1. Śledzi ostatnie wartości i wykrywa lokalne minima (stan spoczynku)
/// 2. Oblicza średnią z ostatnich N minimów
/// 3. Oblicza offset korekcyjny = targetBaseline - średnia_minimów
/// 4. Stosuje płynną korekcję (exponential smoothing)
/// =============================================================================
class BaselineDriftCompensator {
  // Parametry konfiguracyjne
  double targetBaseline;          // Docelowa wartość bazowa (domyślnie 20%)
  int windowSize;                 // Ilość próbek do analizy lokalnego minimum
  int minSamplesBetweenMinima;    // Minimalna liczba próbek między minimami (zapobiega fałszywym detekcjom)
  double smoothingFactor;         // Współczynnik wygładzania offsetu (0-1, wyższy = szybsza adaptacja)
  double maxCorrectionPerSample;  // Maksymalna zmiana korekcji na próbkę (zapobiega skokom)
  bool enabled;                   // Czy kompensacja jest włączona
  
  // Stan wewnętrzny
  final Queue<double> _recentValues = Queue<double>();
  final List<double> _detectedMinima = [];
  int _samplesSinceLastMinimum = 0;
  double _currentOffset = 0.0;
  double _targetOffset = 0.0;
  int _totalSamples = 0;
  
  // Konfiguracja detekcji minimów
  static const int _maxStoredMinima = 10;      // Ile minimów pamiętać
  static const double _minimumThreshold = 35.0; // Minima muszą być poniżej tej wartości
  
  BaselineDriftCompensator({
    this.targetBaseline = 20.0,
    this.windowSize = 5,
    this.minSamplesBetweenMinima = 15,  // ~1.5s przy 10Hz
    this.smoothingFactor = 0.1,
    this.maxCorrectionPerSample = 0.5,
    this.enabled = true,
  });
  
  /// Przetwarza nową wartość i zwraca skorygowaną wartość
  double process(double inputValue) {
    _totalSamples++;
    _samplesSinceLastMinimum++;
    
    // Dodaj do bufora ostatnich wartości
    _recentValues.addLast(inputValue);
    if (_recentValues.length > windowSize) {
      _recentValues.removeFirst();
    }
    
    // Nie przetwarzaj jeśli wyłączone lub za mało danych
    if (!enabled || _recentValues.length < windowSize) {
      return inputValue;
    }
    
    // Sprawdź czy środkowa wartość jest lokalnym minimum
    _checkForLocalMinimum();
    
    // Oblicz docelowy offset na podstawie wykrytych minimów
    _calculateTargetOffset();
    
    // Płynnie dostosuj bieżący offset do docelowego
    _smoothOffset();
    
    // Zastosuj korekcję
    double correctedValue = inputValue + _currentOffset;
    
    // Ogranicz do sensownego zakresu
    return correctedValue.clamp(0.0, 100.0);
  }
  
  /// Sprawdza czy środkowa wartość w oknie jest lokalnym minimum
  void _checkForLocalMinimum() {
    if (_recentValues.length < windowSize) return;
    if (_samplesSinceLastMinimum < minSamplesBetweenMinima) return;
    
    List<double> values = _recentValues.toList();
    int midIndex = windowSize ~/ 2;
    double midValue = values[midIndex];
    
    // Sprawdź czy wartość jest poniżej progu (nie szczyty wdechów)
    if (midValue > _minimumThreshold) return;
    
    // Sprawdź czy to lokalne minimum
    bool isMinimum = true;
    for (int i = 0; i < values.length; i++) {
      if (i != midIndex && values[i] < midValue) {
        isMinimum = false;
        break;
      }
    }
    
    if (isMinimum) {
      _detectedMinima.add(midValue);
      _samplesSinceLastMinimum = 0;
      
      // Ogranicz liczbę przechowywanych minimów
      while (_detectedMinima.length > _maxStoredMinima) {
        _detectedMinima.removeAt(0);
      }
      
      print('📉 Wykryto minimum: ${midValue.toStringAsFixed(1)}%, '
            'średnia minimów: ${_averageMinima.toStringAsFixed(1)}%');
    }
  }
  
  /// Oblicza średnią z wykrytych minimów
  double get _averageMinima {
    if (_detectedMinima.isEmpty) return targetBaseline;
    return _detectedMinima.reduce((a, b) => a + b) / _detectedMinima.length;
  }
  
  /// Oblicza docelowy offset korekcyjny
  void _calculateTargetOffset() {
    if (_detectedMinima.length < 2) {
      // Za mało danych - nie koryguj jeszcze
      _targetOffset = 0.0;
      return;
    }
    
    // Offset = różnica między celem a rzeczywistą średnią minimów
    _targetOffset = targetBaseline - _averageMinima;
    
    // Ogranicz maksymalny offset (zapobiega dzikim korekcjom)
    _targetOffset = _targetOffset.clamp(-30.0, 30.0);
  }
  
  /// Płynnie dostosowuje bieżący offset do docelowego
  void _smoothOffset() {
    double diff = _targetOffset - _currentOffset;
    
    // Ogranicz prędkość zmiany
    if (diff.abs() > maxCorrectionPerSample) {
      diff = diff.sign * maxCorrectionPerSample;
    }
    
    // Zastosuj wygładzanie exponential
    _currentOffset += diff * smoothingFactor;
  }
  
  /// Resetuje kompensator
  void reset() {
    _recentValues.clear();
    _detectedMinima.clear();
    _samplesSinceLastMinimum = 0;
    _currentOffset = 0.0;
    _targetOffset = 0.0;
    _totalSamples = 0;
    print('🔄 Kompensator dryfu zresetowany');
  }
  
  /// Wymusza natychmiastową rekalibrację do bieżącej wartości
  void forceRecalibrate(double currentValue) {
    _detectedMinima.clear();
    _detectedMinima.add(currentValue);
    _calculateTargetOffset();
    _currentOffset = _targetOffset; // Natychmiastowa zmiana
    print('⚡ Wymuszona rekalibracja do ${currentValue.toStringAsFixed(1)}%');
  }
  
  /// Diagnostyka stanu kompensatora
  String getDiagnostics() {
    return 'DriftCompensator('
           'enabled: $enabled, '
           'offset: ${_currentOffset.toStringAsFixed(2)}, '
           'targetOffset: ${_targetOffset.toStringAsFixed(2)}, '
           'detectedMinima: ${_detectedMinima.length}, '
           'avgMinima: ${_averageMinima.toStringAsFixed(1)}%, '
           'samples: $_totalSamples)';
  }
  
  // Gettery stanu
  double get currentOffset => _currentOffset;
  double get targetOffset => _targetOffset;
  int get detectedMinimaCount => _detectedMinima.length;
  double get averageMinima => _averageMinima;
  List<double> get recentMinima => List.unmodifiable(_detectedMinima);
}

/// =============================================================================
/// KONWERTER SUROWYCH WARTOŚCI NA PROCENTY (Z KOMPENSACJĄ DRYFU)
/// =============================================================================
class StretchConverter {
  CalibrationData? _calibration;
  
  // Parametry konwersji (można dostosować)
  double deadZone = 0.3;           // Strefa martwa wokół baseline
  double baselinePercent = 20.0;   // Baseline = 20%
  
  // Użytkownik może nadpisać wartości min/max
  double? _userMin;
  double? _userMax;
  
  // NOWE: Kompensator dryfu bazowego
  final BaselineDriftCompensator _driftCompensator = BaselineDriftCompensator();
  
  // Getter do kompensatora (dla konfiguracji z UI)
  BaselineDriftCompensator get driftCompensator => _driftCompensator;
  
  CalibrationData? get calibration => _calibration;
  
  void setCalibration(CalibrationData calib) {
    _calibration = calib;
    _driftCompensator.reset(); // Reset kompensatora przy nowej kalibracji
    print('✅ Kalibracja ustawiona: $calib');
  }
  
  void setUserRange(double? min, double? max) {
    _userMin = min;
    _userMax = max;
    print('🎯 Zakres użytkownika: min=$min, max=$max');
  }
  
  void clearUserRange() {
    _userMin = null;
    _userMax = null;
    print('🔄 Zakres użytkownika wyczyszczony');
  }
  
  /// NOWE: Włącz/wyłącz kompensację dryfu
  void setDriftCompensationEnabled(bool enabled) {
    _driftCompensator.enabled = enabled;
    if (!enabled) {
      _driftCompensator.reset();
    }
    print('📊 Kompensacja dryfu: ${enabled ? "włączona" : "wyłączona"}');
  }
  
  /// NOWE: Resetuj kompensator dryfu
  void resetDriftCompensation() {
    _driftCompensator.reset();
  }
  
  /// Konwertuje surową wartość na procenty (0-100%) z kompensacją dryfu
  double convertToPercent(double rawValue) {
    if (_calibration == null) {
      // Brak kalibracji - zwróć baseline
      return baselinePercent;
    }
    
    final baseline = _calibration!.baseline;
    final min = _userMin ?? _calibration!.min;
    final max = _userMax ?? _calibration!.max;
    
    // Oblicz różnicę od baseline
    final diff = rawValue - baseline;
    
    // Dead zone: jeśli różnica jest w zakresie ±deadZone, zwróć baselinePercent
    double percent;
    if (diff.abs() <= deadZone) {
      percent = baselinePercent;
    }
    // Jeśli wartość poniżej baseline - dead_zone (kompresja)
    // Mapuj na 0-baselinePercent% (im większa kompresja, tym bliżej 0%)
    else if (diff < -deadZone) {
      final adjustedDiff = diff + deadZone; // Wartość ujemna
      final compressionRange = baseline - min;
      
      if (compressionRange <= 0) {
        percent = baselinePercent;
      } else {
        // Mapuj kompresję na 0-baselinePercent%
        percent = baselinePercent + (adjustedDiff / compressionRange) * baselinePercent;
        // Ogranicz do 0-baselinePercent%
        percent = percent.clamp(0.0, baselinePercent);
      }
    }
    // Jeśli powyżej baseline + dead_zone - mapuj na baselinePercent-100%
    else {
      final adjustedDiff = diff - deadZone;
      final stretchRange = max - baseline;
      
      if (stretchRange <= 0) {
        percent = baselinePercent;
      } else {
        // Mapuj na procent: baselinePercent% przy dead_zone, 100% przy MAX
        percent = baselinePercent + (adjustedDiff / stretchRange) * (100.0 - baselinePercent);
        // Ogranicz do baselinePercent-100%
        percent = percent.clamp(baselinePercent, 100.0);
      }
    }
    
    // NOWE: Zastosuj kompensację dryfu
    percent = _driftCompensator.process(percent);
    
    return percent;
  }
  
  /// Informacje diagnostyczne
  String getDiagnostics(double rawValue) {
    if (_calibration == null) return 'Brak kalibracji';
    
    final baseline = _calibration!.baseline;
    final diff = rawValue - baseline;
    final percent = convertToPercent(rawValue);
    
    String state;
    if (diff.abs() <= deadZone) {
      state = 'SPOCZYNEK';
    } else if (diff > deadZone) {
      state = 'ROZCIĄGANIE';
    } else {
      state = 'KOMPRESJA';
    }
    
    return 'Raw: ${rawValue.toStringAsFixed(3)}, '
           'Diff: ${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(3)}, '
           'Percent: ${percent.toStringAsFixed(1)}%, '
           'State: $state, '
           'DriftOffset: ${_driftCompensator.currentOffset.toStringAsFixed(2)}';
  }
  
  /// Pełna diagnostyka z kompensatorem
  String getFullDiagnostics(double rawValue) {
    return '${getDiagnostics(rawValue)}\n${_driftCompensator.getDiagnostics()}';
  }
}

/// Wyjątek dla uszkodzonego pakietu
class PacketCorruptedException implements Exception {
  final String message;
  PacketCorruptedException(this.message);
  
  @override
  String toString() => 'PacketCorruptedException: $message';
}

/// Wyjątek dla utraconego pakietu
class PacketLostException implements Exception {
  final List<int> lostSequences;
  PacketLostException(this.lostSequences);
  
  @override
  String toString() => 'PacketLostException: Lost packets: $lostSequences';
}