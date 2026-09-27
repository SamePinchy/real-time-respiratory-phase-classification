import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/breath_data_model.dart';
import '../models/ble_protocol.dart';

class BLEService {
  static final BLEService _instance = BLEService._internal();
  factory BLEService() => _instance;
  BLEService._internal();

  // UUID do dostosowania
  static const String serviceUUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String characteristicUUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String ackCharacteristicUUID = "beb5483e-36e1-4688-b7f5-ea07361b26a9";
  static const String calibCharacteristicUUID = "beb5483e-36e1-4688-b7f5-ea07361b26aa";
  static const double _calibMargin = 0.10;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _dataCharacteristic;
  BluetoothCharacteristic? _ackCharacteristic;
  
  // Konwerter surowych wartości na procenty (z kompensacją dryfu)
  final StretchConverter _converter = StretchConverter();
  
  // Auto-reconnect
  bool _autoReconnectEnabled = true;
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  String? _lastDeviceId;
  static const Duration _reconnectInterval = Duration(seconds: 3);
  
  // 🔄 OPCJA RETRANSMISJI
  bool _retransmissionEnabled = false;
  bool get retransmissionEnabled => _retransmissionEnabled;
  
  void setRetransmissionEnabled(bool enabled) {
    _retransmissionEnabled = enabled;
    print('🔄 Retransmisja ${enabled ? "włączona" : "wyłączona"}');
  }
  
  // ✅ OPCJA ACK (POTWIERDZEŃ)
  bool _ackEnabled = true;
  bool get ackEnabled => _ackEnabled;
  
  void setAckEnabled(bool enabled) {
    _ackEnabled = enabled;
    print('✅ ACK ${enabled ? "włączone" : "wyłączone"}');
  }
  
  // 📡 TRYB ŁADUNKU SUROWEGO (urządzenie bez koperty protokolarnej)
  // Gdy false — pełny protokół: JSON, suma kontrolna, numeracja, ACK.
  // Gdy true  — ładunek jest gołą liczbą w ASCII; warstwa protokolarna
  //             pozostaje w kodzie, ale nie jest wymagana od urządzenia.
  bool _rawPayloadMode = false;
  bool get rawPayloadMode => _rawPayloadMode;

  void setRawPayloadMode(bool enabled) {
    _rawPayloadMode = enabled;
    print('📡 Tryb ładunku surowego ${enabled ? "włączony" : "wyłączony"}');
  }

  // Nazwy urządzeń nadających bez koperty protokolarnej
  static const List<String> rawPayloadDeviceKeywords = [
    'pas_tensometryczny',
    'tensometr',
  ];

  // 📐 KALIBRACJA KROCZĄCA (tylko tryb ładunku surowego)
  // Zakres min/max wyznaczany z okna przesuwnego, baseline jako
  // zadany procent rozpiętości. Nie dotyczy pierwszego urządzenia,
  // które otrzymuje kalibrację z osobnej charakterystyki.
  final List<double> _calibWindow = [];
  static const int _calibWindowSamples = 120;  // ≈ 12 s przy 10 Hz (~3 cykle)
  static const int _calibWarmupSamples = 60;   // ≈ 6 s zanim pierwsza kalibracja
  static const int _calibUpdateEvery = 10;     // przeliczanie co 10 próbek
  static const double _calibMinSpan = 3000.0;  // minimalna rozpiętość w zliczeniach

  void _updateRollingCalibration() {
    if (_calibWindow.length < _calibWarmupSamples) return;
    if (_receivedPackets % _calibUpdateEvery != 0) return;

    double mn = _calibWindow.first;
    double mx = _calibWindow.first;
    for (final v in _calibWindow) {
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }

    final double span = mx - mn;

    // Zbyt mała rozpiętość — bezdech albo pas nieruchomy.
    // Zachowujemy poprzednią kalibrację zamiast rozciągać szum na pełną skalę.
    if (span < _calibMinSpan) return;

    // Zapas po obu stronach, żeby szczyty wdechu i wydechu nie były przycinane
    final double margin = span * _calibMargin;
    final double lo = mn - margin;
    final double hi = mx + margin;
    final double paddedSpan = hi - lo;

    final double frac = _converter.baselinePercent / 100.0;

    _converter.setCalibration(CalibrationData(
      baseline: lo + paddedSpan * frac,
      min: lo,
      max: hi,
      calibrationFactor: 1.0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  bool _isRawPayloadDevice(String platformName) {
    final name = platformName.toLowerCase();
    return rawPayloadDeviceKeywords.any((k) => name.contains(k));
  }

  // ♻️ OPCJA AUTO-RECONNECT
  bool get autoReconnectEnabled => _autoReconnectEnabled;
  bool get isReconnecting => _isReconnecting;
  
  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnectEnabled = enabled;
    print('♻️ Auto-reconnect ${enabled ? "włączony" : "wyłączony"}');
    
    if (!enabled) {
      _stopReconnectAttempts();
    }
  }
  
  // ============================================================================
  // NOWE: KOMPENSACJA DRYFU BAZOWEGO
  // ============================================================================
  
  /// Czy kompensacja dryfu jest włączona
  bool get driftCompensationEnabled => _converter.driftCompensator.enabled;
  
  /// Włącz/wyłącz kompensację dryfu bazowego
  void setDriftCompensationEnabled(bool enabled) {
    _converter.setDriftCompensationEnabled(enabled);
  }
  
  /// Resetuj kompensator dryfu (np. po założeniu pasa od nowa)
  void resetDriftCompensation() {
    _converter.resetDriftCompensation();
  }
  
  /// Wymuś rekalibrację dryfu do bieżącej wartości jako baseline
  void forceDriftRecalibration(double currentValue) {
    _converter.driftCompensator.forceRecalibrate(currentValue);
  }
  
  /// Pobierz diagnostykę kompensatora dryfu
  String getDriftCompensatorDiagnostics() {
    return _converter.driftCompensator.getDiagnostics();
  }
  
  /// Pobierz aktualny offset korekcyjny
  double get currentDriftOffset => _converter.driftCompensator.currentOffset;
  
  /// Pobierz średnią z wykrytych minimów
  double get averageDetectedMinima => _converter.driftCompensator.averageMinima;
  
  /// Pobierz liczbę wykrytych minimów
  int get detectedMinimaCount => _converter.driftCompensator.detectedMinimaCount;
  
  /// Ustaw parametry kompensatora dryfu
  void configureDriftCompensator({
    double? targetBaseline,
    int? windowSize,
    int? minSamplesBetweenMinima,
    double? smoothingFactor,
    double? maxCorrectionPerSample,
  }) {
    final comp = _converter.driftCompensator;
    if (targetBaseline != null) comp.targetBaseline = targetBaseline;
    if (windowSize != null) comp.windowSize = windowSize;
    if (minSamplesBetweenMinima != null) comp.minSamplesBetweenMinima = minSamplesBetweenMinima;
    if (smoothingFactor != null) comp.smoothingFactor = smoothingFactor;
    if (maxCorrectionPerSample != null) comp.maxCorrectionPerSample = maxCorrectionPerSample;
    
    print('⚙️ Skonfigurowano kompensator dryfu: ${comp.getDiagnostics()}');
  }
  
  // ============================================================================
  
  // Parametry konwersji (dostępne do modyfikacji)
  double get deadZone => _converter.deadZone;
  set deadZone(double value) => _converter.deadZone = value;
  
  double get baselinePercent => _converter.baselinePercent;
  set baselinePercent(double value) => _converter.baselinePercent = value;
  
  CalibrationData? get calibration => _converter.calibration;
  
  // Monitoring transmisji
  int _expectedSequenceNumber = 0;
  int _receivedPackets = 0;
  int _lostPackets = 0;
  int _corruptedPackets = 0;
  final List<int> _lostSequenceNumbers = [];
  
  // Timeouty i watchdog
  Timer? _connectionWatchdog;
  DateTime? _lastPacketTime;
  static const Duration _packetTimeout = Duration(seconds: 3);
  static const Duration _watchdogInterval = Duration(seconds: 1);
  
  // RSSI monitoring
  int _currentRSSI = 0;
  Timer? _rssiMonitor;
  
  final _dataStreamController = StreamController<BreathData>.broadcast();
  Stream<BreathData> get dataStream => _dataStreamController.stream;

  final _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionStateController.stream;

  final _connectionQualityController = StreamController<ConnectionQuality>.broadcast();
  Stream<ConnectionQuality> get connectionQualityStream => _connectionQualityController.stream;

  final _statisticsController = StreamController<TransmissionStatistics>.broadcast();
  Stream<TransmissionStatistics> get statisticsStream => _statisticsController.stream;

  final _calibrationController = StreamController<CalibrationData>.broadcast();
  Stream<CalibrationData> get calibrationStream => _calibrationController.stream;

  final _rawDataController = StreamController<double>.broadcast();
  Stream<double> get rawDataStream => _rawDataController.stream;
  
  // NOWE: Stream diagnostyki dryfu
  final _driftDiagnosticsController = StreamController<DriftDiagnostics>.broadcast();
  Stream<DriftDiagnostics> get driftDiagnosticsStream => _driftDiagnosticsController.stream;

  bool get isConnected => _connectedDevice != null;
  
  TransmissionStatistics get currentStatistics => TransmissionStatistics(
    receivedPackets: _receivedPackets,
    lostPackets: _lostPackets,
    corruptedPackets: _corruptedPackets,
    packetLossRate: _receivedPackets > 0 
        ? (_lostPackets / (_receivedPackets + _lostPackets)) * 100 
        : 0,
    rssi: _currentRSSI,
  );

  // Skanowanie urządzeń BLE
  Stream<List<ScanResult>> scanForDevices() {
    return FlutterBluePlus.scanResults;
  }

  Future<void> startScan() async {
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      print('Error starting scan: $e');
      rethrow;
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  // Łączenie z urządzeniem
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      // Reset statystyk
      _resetStatistics();
      
      // Reset kompensatora dryfu przy nowym połączeniu
      _converter.resetDriftCompensation();
      
      // Zapisz ID urządzenia dla auto-reconnect
      _lastDeviceId = device.remoteId.toString();
      print('💾 Zapisano ID urządzenia: $_lastDeviceId');

      // Wybór trybu protokołu na podstawie nazwy urządzenia
      _rawPayloadMode = _isRawPayloadDevice(device.platformName);
      _calibWindow.clear();
      if (_rawPayloadMode) {
        // Kalibracja krocząca sama nadąża za dryfem — kompensator
        // działający na procentach byłby drugą korektą tego samego.
        _converter.setDriftCompensationEnabled(false);
      }
      print(_rawPayloadMode
          ? '📡 "${device.platformName}" — tryb ładunku surowego'
          : '📡 "${device.platformName}" — pełny protokół');
      
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      
      _connectedDevice = device;
      _connectionStateController.add(true);

      // Odkryj serwisy
      List<BluetoothService> services = await device.discoverServices();
      
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          for (var characteristic in service.characteristics) {
            String charUUID = characteristic.uuid.toString().toLowerCase();
            
            // Charakterystyka danych (surowe wartości)
            if (charUUID == characteristicUUID.toLowerCase()) {
              _dataCharacteristic = characteristic;
              
              print('📍 Found data characteristic: $charUUID');
              print('📍 Properties: ${characteristic.properties}');
              
              // Włącz notyfikacje
              await characteristic.setNotifyValue(true);
              print('✔ Notifications enabled');
              
              // Nasłuchuj danych
              characteristic.value.listen(
                (value) {
                  print('📦 RAW DATA RECEIVED: ${value.length} bytes');
                  _handleIncomingData(value);
                },
                onError: (error) {
                  print('❌ Data stream error: $error');
                  _handleConnectionError();
                },
                cancelOnError: false,
              );
              
              print('✔ Data characteristic connected and listening');
            }
            
            // Charakterystyka ACK (opcjonalna)
            if (charUUID == ackCharacteristicUUID.toLowerCase()) {
              _ackCharacteristic = characteristic;
              print('✔ ACK characteristic connected');
            }
            
            // Charakterystyka kalibracji
            if (charUUID == calibCharacteristicUUID.toLowerCase()) {
              // Włącz notyfikacje dla kalibracji
              await characteristic.setNotifyValue(true);
              
              // Nasłuchuj danych kalibracyjnych
              characteristic.value.listen(
                (value) {
                  print('📊 CALIBRATION DATA RECEIVED: ${value.length} bytes');
                  _handleCalibrationData(value);
                },
                onError: (error) {
                  print('⚠ Calibration stream error: $error');
                },
                cancelOnError: false,
              );
              
              // Odczytaj dane kalibracyjne
              try {
                List<int> calibValue = await characteristic.read();
                if (calibValue.isNotEmpty) {
                  _handleCalibrationData(calibValue);
                }
              } catch (e) {
                print('⚠ Could not read initial calibration: $e');
              }
              
              print('✔ Calibration characteristic connected');
            }
          }
        }
      }

      if (_dataCharacteristic == null) {
        throw Exception('Data characteristic not found');
      }

      // Uruchom monitoring połączenia
      _startConnectionMonitoring(device);
      _startRSSIMonitoring(device);

      // Nasłuchuj rozłączenia
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      print('✔ Connected successfully to ${device.platformName}');

    } catch (e) {
      print('✗ Error connecting to device: $e');
      _connectionStateController.add(false);
      rethrow;
    }
  }

  void _handleCalibrationData(List<int> value) {
    try {
      String jsonString = utf8.decode(value);
      print('📊 Calibration JSON: $jsonString');
      
      Map<String, dynamic> json = jsonDecode(jsonString);
      CalibrationData calibration = CalibrationData.fromJson(json);
      
      // Ustaw kalibrację w konwerterze
      _converter.setCalibration(calibration);
      
      // Wyemituj przez stream
      _calibrationController.add(calibration);
      
      print('✅ Calibration loaded: $calibration');
    } catch (e) {
      print('❌ Error parsing calibration data: $e');
    }
  }

  void _handleIncomingData(List<int> value) {
    
    if (_rawPayloadMode) {
      _handleRawPayload(value);
      return;
    }

    try {
      _lastPacketTime = DateTime.now();
      
      // Dekoduj JSON
      String jsonString = utf8.decode(value);
      print('📥 Received JSON: $jsonString');
      
      Map<String, dynamic> json = jsonDecode(jsonString);
      
      // Parsuj pakiet z weryfikacją
      BLEPacket packet;
      try {
        int seq = json['seq'];
        double rawValue = (json['raw'] as num).toDouble();
        int ts = json['ts'];
        String receivedChecksum = json['checksum'];
        
        print('🔍 Verifying: seq=$seq, raw=$rawValue, ts=$ts');
        print('🔍 Received checksum: $receivedChecksum');
        
        packet = BLEPacket.fromJson(json);
        print('✔ Packet verified! seq=$seq');
      } on PacketCorruptedException catch (e) {
        _corruptedPackets++;
        print('✗ Corrupted packet: $e');
        _updateStatistics();
        return;
      }
      
      // Sprawdź sekwencję
      if (packet.sequenceNumber != _expectedSequenceNumber) {
        // Wykryto utracone pakiety
        List<int> lost = [];
        for (int i = _expectedSequenceNumber; i < packet.sequenceNumber; i++) {
          lost.add(i);
          _lostSequenceNumbers.add(i);
        }
        _lostPackets += lost.length;
        print('⚠ Lost packets: $lost');
        
        // Opcjonalnie: wyślij żądanie retransmisji (tylko jeśli włączone)
        if (_retransmissionEnabled) {
          _requestRetransmission(lost);
        } else {
          print('ℹ️ Retransmisja wyłączona - pomijam zagubione pakiety');
        }
      }
      
      _expectedSequenceNumber = packet.sequenceNumber + 1;
      _receivedPackets++;
      
      // Wyślij ACK
      _sendAcknowledgment(packet.sequenceNumber);
      
      // Wyemituj surowe dane
      _rawDataController.add(packet.rawValue);
      
      // Konwertuj na procenty (z automatyczną kompensacją dryfu)
      double stretch = _converter.convertToPercent(packet.rawValue);
      
      // Konwertuj na BreathData
      BreathData data = BreathData(
        timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
        stretch: stretch,
        rawValue: packet.rawValue, // Dodajemy surową wartość
      );
      
      _dataStreamController.add(data);
      _updateStatistics();
      
      // Emituj diagnostykę dryfu co 10 pakiet
      if (_receivedPackets % 10 == 0) {
        _emitDriftDiagnostics(stretch);
        
        print('📊 Received $_receivedPackets packets, Lost: $_lostPackets, Corrupted: $_corruptedPackets');
        print('🎯 ${_converter.getDiagnostics(packet.rawValue)}');
      }
      
    } catch (e) {
      print('✗ Error parsing data: $e');
      _corruptedPackets++;
      _updateStatistics();
    }
  }

    /// Obsługa ładunku bez koperty protokolarnej.
  /// Urządzenie nadaje gołą liczbę w ASCII — bez numeru sekwencyjnego,
  /// znacznika czasu i sumy kontrolnej. Numeracja i czas są nadawane
  /// lokalnie, weryfikacja integralności nie jest wykonywana.
  void _handleRawPayload(List<int> value) {
    try {
      _lastPacketTime = DateTime.now();

      // Puste powiadomienie (typowe zaraz po włączeniu notyfikacji)
      if (value.isEmpty) {
        print('ℹ️ Pusty pakiet — pomijam');
        return;
      }

      final String payload = utf8.decode(value).trim();
      print('📥 Odebrano surowy ładunek: $payload');

      if (payload.isEmpty) {
        print('ℹ️ Pusty ładunek po oczyszczeniu — pomijam');
        return;
      }

      final double? rawValue = double.tryParse(payload);
      if (rawValue == null) {
        print('⚠ Ładunek nieliczbowy: "$payload"');
        _corruptedPackets++;
        _updateStatistics();
        return;
      }

      // Okno przesuwne dla kalibracji kroczącej
      _calibWindow.add(rawValue);
      if (_calibWindow.length > _calibWindowSamples) {
        _calibWindow.removeAt(0);
      }

      // Numeracja lokalna — urządzenie jej nie nadaje,
      // więc strat pakietów nie da się wykryć.
      _expectedSequenceNumber = _receivedPackets + 1;
      _receivedPackets++;

      _updateRollingCalibration();

      // Wyemituj surowe dane
      _rawDataController.add(rawValue);

      // Konwertuj na procenty (z automatyczną kompensacją dryfu)
      double stretch = _converter.convertToPercent(rawValue);

      // Znacznik czasu z zegara telefonu — urządzenie go nie podaje
      BreathData data = BreathData(
        timestamp: DateTime.now(),
        stretch: stretch,
        rawValue: rawValue,
      );

      _dataStreamController.add(data);
      _updateStatistics();

      if (_receivedPackets % 10 == 0) {
        _emitDriftDiagnostics(stretch);
        print('📊 [surowy] Odebrano $_receivedPackets próbek');
        print('🎯 ${_converter.getDiagnostics(rawValue)}');
      }
    } catch (e) {
      print('✗ Błąd parsowania (tryb surowy): $e');
      _corruptedPackets++;
      _updateStatistics();
    }
  }
  
  void _emitDriftDiagnostics(double currentStretch) {
    final diag = DriftDiagnostics(
      enabled: _converter.driftCompensator.enabled,
      currentOffset: _converter.driftCompensator.currentOffset,
      targetOffset: _converter.driftCompensator.targetOffset,
      averageMinima: _converter.driftCompensator.averageMinima,
      detectedMinimaCount: _converter.driftCompensator.detectedMinimaCount,
      currentStretch: currentStretch,
    );
    _driftDiagnosticsController.add(diag);
  }

  Future<void> _sendAcknowledgment(int sequenceNumber) async {
    if (_ackCharacteristic == null || !_ackEnabled) return;
    
    try {
      Map<String, dynamic> ack = {
        'ack': sequenceNumber,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      
      String ackJson = jsonEncode(ack);
      await _ackCharacteristic!.write(utf8.encode(ackJson));
    } catch (e) {
      print('⚠ Failed to send ACK: $e');
    }
  }

  Future<void> _requestRetransmission(List<int> lostSequences) async {
    if (_ackCharacteristic == null || lostSequences.isEmpty) return;
    
    try {
      Map<String, dynamic> request = {
        'retransmit': lostSequences,
      };
      
      String requestJson = jsonEncode(request);
      await _ackCharacteristic!.write(utf8.encode(requestJson));
      print('↻ Requested retransmission of: $lostSequences');
    } catch (e) {
      print('⚠ Failed to request retransmission: $e');
    }
  }

  /// Żądanie rekalibracji z ESP32
  Future<void> requestRecalibration() async {
    if (_ackCharacteristic == null) {
      print('⚠ Cannot recalibrate - ACK characteristic not available');
      return;
    }
    
    try {
      Map<String, dynamic> request = {
        'recalibrate': true,
      };
      
      String requestJson = jsonEncode(request);
      await _ackCharacteristic!.write(utf8.encode(requestJson));
      
      // Reset kompensatora dryfu przy rekalibracji
      _converter.resetDriftCompensation();
      
      print('🔄 Requested recalibration from ESP32');
    } catch (e) {
      print('⚠ Failed to request recalibration: $e');
      rethrow;
    }
  }

  /// Ustawienie niestandardowego zakresu użytkownika
  void setUserCalibrationRange(double? min, double? max) {
    _converter.setUserRange(min, max);
  }

  /// Wyczyszczenie niestandardowego zakresu
  void clearUserCalibrationRange() {
    _converter.clearUserRange();
  }

  /// Pobierz diagnostykę dla surowej wartości
  String getDiagnostics(double rawValue) {
    return _converter.getDiagnostics(rawValue);
  }
  
  /// Pobierz pełną diagnostykę z kompensatorem dryfu
  String getFullDiagnostics(double rawValue) {
    return _converter.getFullDiagnostics(rawValue);
  }
  

  void _startConnectionMonitoring(BluetoothDevice device) {
    _connectionWatchdog?.cancel();
    
    _connectionWatchdog = Timer.periodic(_watchdogInterval, (timer) {
      if (_lastPacketTime != null) {
        final timeSinceLastPacket = DateTime.now().difference(_lastPacketTime!);
        
        if (timeSinceLastPacket > _packetTimeout) {
          print('⚠ No data received for ${timeSinceLastPacket.inSeconds}s');
          
          // Sprawdź czy połączenie nadal istnieje
          device.connectionState.first.then((state) {
            if (state == BluetoothConnectionState.disconnected) {
              _handleDisconnection();
            }
          });
        }
      }
    });
  }

  void _startRSSIMonitoring(BluetoothDevice device) {
    _rssiMonitor?.cancel();
    
    _rssiMonitor = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        _currentRSSI = await device.readRssi();
        
        // Określ jakość połączenia na podstawie RSSI
        ConnectionQuality quality;
        if (_currentRSSI >= -60) {
          quality = ConnectionQuality.excellent;
        } else if (_currentRSSI >= -70) {
          quality = ConnectionQuality.good;
        } else if (_currentRSSI >= -80) {
          quality = ConnectionQuality.fair;
        } else {
          quality = ConnectionQuality.poor;
        }
        
        _connectionQualityController.add(quality);
        
        if (_currentRSSI < -85) {
          print('⚠ Weak signal: $_currentRSSI dBm');
        }
      } catch (e) {
        print('⚠ Failed to read RSSI: $e');
      }
    });
  }

  void _handleConnectionError() {
    print('✗ Connection error detected');
  }

  void _handleDisconnection() {
    print('✗ Device disconnected');
    
    _connectionWatchdog?.cancel();
    _rssiMonitor?.cancel();
    
    final wasConnected = _connectedDevice != null;
    final deviceId = _lastDeviceId;
    
    _connectedDevice = null;
    _dataCharacteristic = null;
    _ackCharacteristic = null;
    
    _connectionStateController.add(false);
    
    // Raport końcowy
    print('📊 Final statistics:');
    print('   Received: $_receivedPackets packets');
    print('   Lost: $_lostPackets packets');
    print('   Corrupted: $_corruptedPackets packets');
    print('   Loss rate: ${currentStatistics.packetLossRate.toStringAsFixed(2)}%');
    print('   Drift offset: ${_converter.driftCompensator.currentOffset.toStringAsFixed(2)}');
    
    // Uruchom auto-reconnect jeśli było połączenie i jest włączone
    if (wasConnected && _autoReconnectEnabled && deviceId != null) {
      print('♻️ Rozpoczynam próby ponownego połączenia...');
      _startReconnectAttempts(deviceId);
    }
  }

  void _resetStatistics() {
    _expectedSequenceNumber = 0;
    _receivedPackets = 0;
    _lostPackets = 0;
    _corruptedPackets = 0;
    _lostSequenceNumbers.clear();
    _lastPacketTime = null;
    _currentRSSI = 0;
  }

  void _updateStatistics() {
    _statisticsController.add(currentStatistics);
  }

  Future<void> disconnect() async {
    // Wyłącz auto-reconnect przy ręcznym rozłączaniu
    _autoReconnectEnabled = false;
    _stopReconnectAttempts();
    
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _handleDisconnection();
    }
  }

  void _startReconnectAttempts(String deviceId) {
    if (_isReconnecting) return;
    
    _isReconnecting = true;
    print('🔄 Szukam urządzenia $deviceId...');
    
    _reconnectTimer = Timer.periodic(_reconnectInterval, (timer) async {
      if (!_autoReconnectEnabled || _connectedDevice != null) {
        _stopReconnectAttempts();
        return;
      }
      
      await _attemptReconnect(deviceId);
    });
  }

  void _stopReconnectAttempts() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isReconnecting = false;
    print('⏹️ Zatrzymano próby ponownego połączenia');
  }

  Future<void> _attemptReconnect(String deviceId) async {
    try {
      print('🔍 Próba ponownego połączenia z $deviceId...');
      
      // Sprawdź czy urządzenie jest dostępne
      final connectedDevices = await FlutterBluePlus.connectedSystemDevices;
      
      for (var device in connectedDevices) {
        if (device.remoteId.toString() == deviceId) {
          print('✅ Znaleziono urządzenie! Łączę...');
          await connectToDevice(device);
          _stopReconnectAttempts();
          return;
        }
      }
      
      // Jeśli nie ma w połączonych, spróbuj przez scan
      final scanResults = FlutterBluePlus.lastScanResults;
      
      for (var result in scanResults) {
        if (result.device.remoteId.toString() == deviceId) {
          print('✅ Znaleziono urządzenie! Łączę...');
          await connectToDevice(result.device);
          _stopReconnectAttempts();
          return;
        }
      }
      
      print('⏳ Urządzenie jeszcze niedostępne, czekam...');
      
    } catch (e) {
      print('⚠️ Błąd podczas próby reconnect: $e');
    }
  }

  void dispose() {
    _connectionWatchdog?.cancel();
    _rssiMonitor?.cancel();
    _reconnectTimer?.cancel();
    _dataStreamController.close();
    _connectionStateController.close();
    _connectionQualityController.close();
    _statisticsController.close();
    _calibrationController.close();
    _rawDataController.close();
    _driftDiagnosticsController.close();
  }
}

// Jakość połączenia
enum ConnectionQuality {
  excellent,  // RSSI >= -60 dBm
  good,       // RSSI >= -70 dBm
  fair,       // RSSI >= -80 dBm
  poor,       // RSSI < -80 dBm
}

// Statystyki transmisji
class TransmissionStatistics {
  final int receivedPackets;
  final int lostPackets;
  final int corruptedPackets;
  final double packetLossRate; // Procent
  final int rssi;

  TransmissionStatistics({
    required this.receivedPackets,
    required this.lostPackets,
    required this.corruptedPackets,
    required this.packetLossRate,
    required this.rssi,
  });

  @override
  String toString() {
    return 'Stats(received: $receivedPackets, lost: $lostPackets, corrupted: $corruptedPackets, loss: ${packetLossRate.toStringAsFixed(1)}%, RSSI: $rssi dBm)';
  }
}

// NOWE: Diagnostyka kompensacji dryfu
class DriftDiagnostics {
  final bool enabled;
  final double currentOffset;
  final double targetOffset;
  final double averageMinima;
  final int detectedMinimaCount;
  final double currentStretch;
  
  DriftDiagnostics({
    required this.enabled,
    required this.currentOffset,
    required this.targetOffset,
    required this.averageMinima,
    required this.detectedMinimaCount,
    required this.currentStretch,
  });
  
  @override
  String toString() {
    return 'DriftDiag(enabled: $enabled, offset: ${currentOffset.toStringAsFixed(2)}, '
           'avgMinima: ${averageMinima.toStringAsFixed(1)}%, minimaCount: $detectedMinimaCount)';
  }
}