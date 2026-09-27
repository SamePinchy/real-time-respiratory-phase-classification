import '../services/cycle_detector.dart';

class BreathData {
  final DateTime timestamp;
  final double stretch;    // Stopień rozciągnięcia (%) - przeliczone
  final double? rawValue;  // Surowa wartość z tensometru (opcjonalna dla zgodności wstecz)

  BreathData({
    required this.timestamp,
    required this.stretch,
    this.rawValue,
  });

  factory BreathData.fromJson(Map<String, dynamic> json) {
    return BreathData(
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      stretch: (json['stretch'] as num).toDouble(),
      rawValue: json['rawValue'] != null ? (json['rawValue'] as num).toDouble() : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'stretch': stretch,
      if (rawValue != null) 'rawValue': rawValue,
    };
  }

  @override
  String toString() {
    if (rawValue != null) {
      return 'BreathData(time: ${timestamp.toIso8601String()}, stretch: $stretch%, raw: $rawValue)';
    }
    return 'BreathData(time: ${timestamp.toIso8601String()}, stretch: $stretch%)';
  }
}

class BreathSession {
  final String id;
  final DateTime startTime;
  DateTime? endTime;
  final List<BreathData> data;
  /// Phase label per data point, stored as int index (0=inhale,1=exhale,
  /// 2=retentionInhale,3=retentionExhale,4=unknown).  Same length as [data].
  final List<int> phaseIndices;

  BreathSession({
    required this.id,
    required this.startTime,
    this.endTime,
    List<BreathData>? data,
    List<int>? phaseIndices,
  })  : data = data ?? [],
        phaseIndices = phaseIndices ?? [];

  Duration get duration {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime);
  }

  /// Number of complete breath cycles (inhale onsets) detected by the classifier.
  int get totalCycles {
    if (phaseIndices.length < 2 || phaseIndices.length != data.length) return 0;
    return _cycleStarts().length;
  }

  /// Accepted cycle starts (shared rule from cycle_detector.dart).
  List<int> _cycleStarts() => detectCycleStarts(
        length: phaseIndices.length,
        valueAt: (i) => data[i].stretch,
        isInhaleAt: (i) => phaseIndices[i] == 0, // 0 = inhale
      );

  // KALKULACJA RYTMU ODDECHU
  double get averageBreathRate {
    // Prefer classifier phases when available
    if (phaseIndices.isNotEmpty && data.length == phaseIndices.length) {
      return _breathRateFromPhases();
    }
    return _breathRateFromPeaks();
  }

  /// Count inhale onsets in [phaseIndices] over the full session.
  double _breathRateFromPhases() {
    if (data.length < 2) return 0;
    final inhaleStarts = _cycleStarts().length;
    if (inhaleStarts == 0) return 0;
    final totalTime = data.last.timestamp
        .difference(data.first.timestamp)
        .inMilliseconds / 1000.0;
    if (totalTime == 0) return 0;
    return inhaleStarts / totalTime * 60;
  }

  double _breathRateFromPeaks() {
    if (data.length < 10) return 0;
    List<int> peaks = _findPeaksImproved(data.map((d) => d.stretch).toList());
    if (peaks.length < 2) return 0;
    double totalTime = data[peaks.last].timestamp
        .difference(data[peaks.first].timestamp)
        .inSeconds
        .toDouble();
    if (totalTime == 0) return 0;
    return (peaks.length - 1) / totalTime * 60;
  }

  // ULEPSZONA DETEKCJA SZCZYTÓW
  List<int> _findPeaksImproved(List<double> values) {
    if (values.length < 10) return [];
    
    List<int> peaks = [];
    
    // Oblicz dynamiczny próg (50% pomiędzy średnią a maksimum)
    double average = values.reduce((a, b) => a + b) / values.length;
    double maximum = values.reduce((a, b) => a > b ? a : b);
    double threshold = average + (maximum - average) * 0.4;
    
    // Minimalna odległość między szczytami (np. 1.5 sekundy = ~15 pomiarów przy 10Hz)
    int minDistanceBetweenPeaks = 15;
    
    int? lastPeakIndex;
    
    for (int i = 2; i < values.length - 2; i++) {
      // Sprawdź czy to szczyt (większy od bezpośrednich sąsiadów)
      bool isLocalMaximum = values[i] > values[i - 1] && 
                            values[i] > values[i + 1] &&
                            values[i] > values[i - 2] && 
                            values[i] > values[i + 2];
      
      // Sprawdź czy przekracza próg
      bool aboveThreshold = values[i] > threshold;
      
      // Sprawdź minimalną odległość od poprzedniego szczytu
      bool farEnoughFromLastPeak = lastPeakIndex == null || 
                                     (i - lastPeakIndex) >= minDistanceBetweenPeaks;
      
      if (isLocalMaximum && aboveThreshold && farEnoughFromLastPeak) {
        peaks.add(i);
        lastPeakIndex = i;
      }
    }
    
    return peaks;
  }

  // ALTERNATYWNA METODA: Zliczanie przejść przez próg (crossing detection)
  double get averageBreathRateAlternative {
    if (data.length < 10) return 0;
    
    List<double> values = data.map((d) => d.stretch).toList();
    
    // Oblicz medianę jako próg
    List<double> sortedValues = List.from(values)..sort();
    double median = sortedValues[sortedValues.length ~/ 2];
    
    // Zlicz przejścia przez medianę (z dołu do góry = wdech)
    int crossings = 0;
    bool wasBelow = values.first < median;
    
    for (int i = 1; i < values.length; i++) {
      bool isAbove = values[i] > median;
      
      if (wasBelow && isAbove) {
        crossings++;
      }
      
      wasBelow = !isAbove;
    }
    
    if (crossings < 2) return 0;
    
    double totalTime = data.last.timestamp
        .difference(data.first.timestamp)
        .inSeconds
        .toDouble();
    
    if (totalTime == 0) return 0;
    
    return crossings / totalTime * 60;
  }

  // Dodatkowe statystyki
  double get minStretch {
    if (data.isEmpty) return 0;
    return data.map((d) => d.stretch).reduce((a, b) => a < b ? a : b);
  }

  double get maxStretch {
    if (data.isEmpty) return 0;
    return data.map((d) => d.stretch).reduce((a, b) => a > b ? a : b);
  }

  double get averageStretch {
    if (data.isEmpty) return 0;
    return data.map((d) => d.stretch).reduce((a, b) => a + b) / data.length;
  }

  // Statystyki surowych wartości (jeśli dostępne)
  double? get minRaw {
    final rawValues = data.where((d) => d.rawValue != null).map((d) => d.rawValue!).toList();
    if (rawValues.isEmpty) return null;
    return rawValues.reduce((a, b) => a < b ? a : b);
  }

  double? get maxRaw {
    final rawValues = data.where((d) => d.rawValue != null).map((d) => d.rawValue!).toList();
    if (rawValues.isEmpty) return null;
    return rawValues.reduce((a, b) => a > b ? a : b);
  }

  double? get averageRaw {
    final rawValues = data.where((d) => d.rawValue != null).map((d) => d.rawValue!).toList();
    if (rawValues.isEmpty) return null;
    return rawValues.reduce((a, b) => a + b) / rawValues.length;
  }

  // Zmienność oddechu (odchylenie standardowe czasu między szczytami)
  double get breathVariability {
    if (data.length < 10) return 0;
    
    List<int> peaks = _findPeaksImproved(data.map((d) => d.stretch).toList());
    
    if (peaks.length < 3) return 0;
    
    // Oblicz czasy między szczytami
    List<double> intervals = [];
    for (int i = 1; i < peaks.length; i++) {
      double interval = data[peaks[i]].timestamp
          .difference(data[peaks[i - 1]].timestamp)
          .inMilliseconds / 1000.0;
      intervals.add(interval);
    }
    
    // Oblicz średnią
    double mean = intervals.reduce((a, b) => a + b) / intervals.length;
    
    // Oblicz odchylenie standardowe
    double variance = intervals
        .map((x) => (x - mean) * (x - mean))
        .reduce((a, b) => a + b) / intervals.length;
    
    return variance;
  }
}