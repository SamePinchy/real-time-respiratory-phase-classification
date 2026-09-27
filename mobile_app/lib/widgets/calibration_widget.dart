import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../services/calibration_settings_service.dart';
import '../models/ble_protocol.dart';

/// Widget do zarządzania kalibracją tensometru
class CalibrationWidget extends StatefulWidget {
  final BLEService bleService;

  const CalibrationWidget({
    Key? key,
    required this.bleService,
  }) : super(key: key);

  @override
  State<CalibrationWidget> createState() => _CalibrationWidgetState();
}

class _CalibrationWidgetState extends State<CalibrationWidget> {
  final CalibrationSettingsService _settingsService = CalibrationSettingsService();
  
  CalibrationData? _currentCalibration;
  bool _isRecalibrating = false;
  
  // Edytowalne wartości zakresu
  final TextEditingController _minController = TextEditingController();
  final TextEditingController _maxController = TextEditingController();
  bool _customRangeEnabled = false;
  
  // Parametry zaawansowane
  double _deadZone = 0.3;
  double _baselinePercent = 20.0;
  
  // Aktualnie używane wartości (dla wyświetlania)
  double? _currentMin;
  double? _currentMax;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _currentCalibration = widget.bleService.calibration;
    
    // Nasłuchuj zmian kalibracji z ESP32
    widget.bleService.calibrationStream.listen((calib) {
      if (mounted) {
        setState(() {
          _currentCalibration = calib;
          _updateCurrentRange();
        });
      }
    });
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _settingsService.loadUserSettings();
      
      if (mounted) {
        setState(() {
          _customRangeEnabled = settings.customRangeEnabled;
          _deadZone = settings.deadZone;
          _baselinePercent = settings.baselinePercent;
          
          // Zastosuj zapisane ustawienia do BLE Service
          widget.bleService.deadZone = _deadZone;
          widget.bleService.baselinePercent = _baselinePercent;
          
          // Jeśli był niestandardowy zakres, przywróć go
          if (_customRangeEnabled && settings.userMin != null && settings.userMax != null) {
            _minController.text = settings.userMin!.toStringAsFixed(3);
            _maxController.text = settings.userMax!.toStringAsFixed(3);
            widget.bleService.setUserCalibrationRange(settings.userMin, settings.userMax);
          }
          
          _updateCurrentRange();
        });
        
        print('✅ Wczytano zapisane ustawienia kalibracji: $settings');
      }
    } catch (e) {
      print('⚠️ Nie udało się wczytać ustawień kalibracji: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      double? userMin;
      double? userMax;
      
      if (_customRangeEnabled) {
        userMin = double.tryParse(_minController.text);
        userMax = double.tryParse(_maxController.text);
      }
      
      await _settingsService.saveUserSettings(
        userMin: userMin,
        userMax: userMax,
        deadZone: _deadZone,
        baselinePercent: _baselinePercent,
        customRangeEnabled: _customRangeEnabled,
      );
      
      print('💾 Zapisano ustawienia kalibracji');
    } catch (e) {
      print('⚠️ Nie udało się zapisać ustawień: $e');
    }
  }

  void _updateCurrentRange() {
    // Pobierz aktualnie używane wartości z BLE Service lub Calibration
    if (_customRangeEnabled) {
      _currentMin = double.tryParse(_minController.text);
      _currentMax = double.tryParse(_maxController.text);
    } else if (_currentCalibration != null) {
      _currentMin = _currentCalibration!.min;
      _currentMax = _currentCalibration!.max;
      // Zaktualizuj kontrolery, jeśli nie ma niestandardowego zakresu
      if (!_customRangeEnabled) {
        _minController.text = _currentMin!.toStringAsFixed(3);
        _maxController.text = _currentMax!.toStringAsFixed(3);
      }
    }
  }

  @override
  void dispose() {
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  Future<void> _requestRecalibration() async {
    setState(() => _isRecalibrating = true);
    
    try {
      await widget.bleService.requestRecalibration();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Żądanie rekalibracji wysłane'),
              ],
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Błąd rekalibracji: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRecalibrating = false);
      }
    }
  }

  void _applyCustomRange() {
    try {
      double? min = double.tryParse(_minController.text);
      double? max = double.tryParse(_maxController.text);
      
      if (min == null || max == null) {
        throw Exception('Nieprawidłowe wartości');
      }
      
      if (min >= max) {
        throw Exception('Min musi być mniejsze niż Max');
      }
      
      widget.bleService.setUserCalibrationRange(min, max);
      
      setState(() {
        _customRangeEnabled = true;
        _updateCurrentRange();
      });
      
      _saveSettings(); // Zapisz po zastosowaniu
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Niestandardowy zakres zastosowany'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Błąd: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _resetToDefault() {
    widget.bleService.clearUserCalibrationRange();
    
    setState(() {
      _customRangeEnabled = false;
      if (_currentCalibration != null) {
        _minController.text = _currentCalibration!.min.toStringAsFixed(3);
        _maxController.text = _currentCalibration!.max.toStringAsFixed(3);
      }
      _updateCurrentRange();
    });
    
    _saveSettings(); // Zapisz po resecie
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Przywrócono domyślny zakres z ESP32'),
        backgroundColor: Colors.blue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune, size: 24),
                const SizedBox(width: 8),
                const Text(
                  'Kalibracja tensometru',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_isRecalibrating)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            
            if (_currentCalibration != null) ...[
              // Informacje o aktualnej kalibracji z ESP32
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Kalibracja z ESP32:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildCalibRow(
                      'Baseline (spoczynek):',
                      _currentCalibration!.baseline.toStringAsFixed(3),
                      Icons.horizontal_rule,
                    ),
                    const SizedBox(height: 8),
                    _buildCalibRow(
                      'Zakres Min (ESP32):',
                      _currentCalibration!.min.toStringAsFixed(3),
                      Icons.arrow_downward,
                    ),
                    const SizedBox(height: 8),
                    _buildCalibRow(
                      'Zakres Max (ESP32):',
                      _currentCalibration!.max.toStringAsFixed(3),
                      Icons.arrow_upward,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Aktualnie używany zakres (może być inny niż ESP32)
              if (_currentMin != null && _currentMax != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Aktualnie używany zakres:',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                          if (_customRangeEnabled) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'NIESTANDARDOWY',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildCalibRow(
                        'Min (używany):',
                        _currentMin!.toStringAsFixed(3),
                        Icons.arrow_downward,
                        color: Colors.green,
                      ),
                      const SizedBox(height: 8),
                      _buildCalibRow(
                        'Max (używany):',
                        _currentMax!.toStringAsFixed(3),
                        Icons.arrow_upward,
                        color: Colors.green,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              
              const Divider(),
              const SizedBox(height: 16),
              
              // Przycisk rekalibracji ESP32
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isRecalibrating ? null : _requestRecalibration,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rekalibruj ESP32'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              ),
              
              const SizedBox(height: 8),
              
              const Text(
                'Nie dotykaj tensometru podczas rekalibracji (3 sekundy)',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              
              // Niestandardowy zakres
              Row(
                children: [
                  const Text(
                    'Niestandardowy zakres:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Switch(
                    value: _customRangeEnabled,
                    onChanged: (value) {
                      setState(() => _customRangeEnabled = value);
                      if (!value) {
                        _resetToDefault();
                      } else {
                        _saveSettings();
                      }
                    },
                  ),
                ],
              ),
              
              if (_customRangeEnabled) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Min',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.arrow_downward),
                        ),
                        onChanged: (_) => setState(() {}), // Aktualizuj UI przy wpisywaniu
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: _maxController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Max',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.arrow_upward),
                        ),
                        onChanged: (_) => setState(() {}), // Aktualizuj UI przy wpisywaniu
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _applyCustomRange,
                        icon: const Icon(Icons.check),
                        label: const Text('Zastosuj'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _resetToDefault,
                        icon: const Icon(Icons.undo),
                        label: const Text('Przywróć'),
                      ),
                    ),
                  ],
                ),
              ],
              
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              
              // Parametry konwersji
              ExpansionTile(
                title: const Text('Parametry zaawansowane'),
                leading: const Icon(Icons.settings),
                children: [
                  _buildParameterSlider(
                    'Dead Zone',
                    _deadZone,
                    0.1,
                    1.0,
                    (value) {
                      setState(() {
                        _deadZone = value;
                        widget.bleService.deadZone = value;
                      });
                      _saveSettings(); // Zapisz po zmianie
                    },
                  ),
                  _buildParameterSlider(
                    'Baseline %',
                    _baselinePercent,
                    0.0,
                    50.0,
                    (value) {
                      setState(() {
                        _baselinePercent = value;
                        widget.bleService.baselinePercent = value;
                      });
                      _saveSettings(); // Zapisz po zmianie
                    },
                  ),
                ],
              ),
            ] else ...[
              // Brak kalibracji
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Brak danych kalibracyjnych. Połącz się z ESP32.',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCalibRow(String label, String value, IconData icon, {Color? color}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color ?? Colors.blue),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 14),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildParameterSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
              Text(
                value.toStringAsFixed(1),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) * 10).toInt(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Dialog kalibracji (kompaktowy)
class CalibrationDialog extends StatelessWidget {
  final BLEService bleService;

  const CalibrationDialog({
    Key? key,
    required this.bleService,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              title: const Text('Kalibracja'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                child: CalibrationWidget(bleService: bleService),
              ),
            ),
          ],
        ),
      ),
    );
  }
}