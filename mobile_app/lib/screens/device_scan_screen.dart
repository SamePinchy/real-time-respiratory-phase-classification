import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import '../providers/breath_provider.dart';
import '../services/ble_service.dart';
import 'monitoring_screen.dart';
import 'history_screen.dart';

class DeviceScanScreen extends StatefulWidget {
  const DeviceScanScreen({Key? key}) : super(key: key);

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  final BLEService _bleService = BLEService();
  bool _isScanning = false;
  bool _showAllDevices = false; // Toggle do pokazywania wszystkich urządzeń

  @override
  void initState() {
    super.initState();
    _startScan();
    _setupConnectionListener();
  }

  void _setupConnectionListener() {
    // Nasłuchuj statusu połączenia dla auto-reconnect
    _bleService.connectionStream.listen((isConnected) {
      if (isConnected && mounted) {
        // Auto-reconnect się powiódł - przejdź do monitoring screen
        print('✅ Auto-reconnect successful! Navigating to monitoring screen...');
        
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const MonitoringScreen(),
          ),
        );
      }
    });
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    try {
      await _bleService.startScan();
      
      // Auto-stop po 15 sekundach
      Future.delayed(const Duration(seconds: 15), () {
        if (mounted) {
          setState(() => _isScanning = false);
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd skanowania: $e')),
        );
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await _bleService.stopScan();
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      await Provider.of<BreathProvider>(context, listen: false)
          .connectToDevice(device);

      if (mounted) {
        Navigator.of(context).pop(); // Zamknij dialog ładowania
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const MonitoringScreen(),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nie udało się połączyć: $e')),
        );
      }
    }
  }

  // Funkcja filtrująca urządzenia ESP
  bool _isESPDevice(BluetoothDevice device) {
    final name = device.platformName.toLowerCase();
    
    // Lista słów kluczowych dla urządzeń ESP
    final espKeywords = [
      'esp32',
      'esp',
      'breath', // Nasza nazwa urządzenia
      'monitor',
      'pas_tensometryczny',
      'tensometryczny',
      'tensometr',
      'pas',
    ];
    
    // Sprawdź czy nazwa zawiera któreś ze słów kluczowych
    return espKeywords.any((keyword) => name.contains(keyword));
  }

  List<ScanResult> _filterDevices(List<ScanResult> devices) {
    if (_showAllDevices) {
      return devices; // Pokaż wszystkie
    }
    
    // Filtruj tylko ESP
    return devices.where((result) => _isESPDevice(result.device)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wyszukiwanie ESP32'),
        actions: [
          // Historia pomiarów
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Historia pomiarów',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
          // Toggle pokazywania wszystkich urządzeń
          IconButton(
            icon: Icon(_showAllDevices ? Icons.filter_alt : Icons.filter_alt_off),
            onPressed: () {
              setState(() {
                _showAllDevices = !_showAllDevices;
              });
            },
            tooltip: _showAllDevices ? 'Pokaż tylko ESP' : 'Pokaż wszystkie',
          ),
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.refresh),
            onPressed: _isScanning ? null : _startScan,
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner auto-reconnect
          StreamBuilder<bool>(
            stream: _bleService.connectionStream,
            builder: (context, snapshot) {
              if (_bleService.isReconnecting) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Colors.orange,
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Próba ponownego połączenia z urządzeniem...',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          _bleService.setAutoReconnectEnabled(false);
                          setState(() {});
                        },
                        child: const Text(
                          'ANULUJ',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          
          // Przycisk trybu testowego
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () async {
                await Provider.of<BreathProvider>(context, listen: false)
                    .connectToMockDevice();
                
                if (mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (context) => const MonitoringScreen(),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.science),
              label: const Text('TRYB TESTOWY (bez ESP32)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(16),
              ),
            ),
          ),
          
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('LUB'),
                ),
                Expanded(child: Divider()),
              ],
            ),
          ),
          
          // Info o filtrze
          if (!_showAllDevices)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pokazuję tylko urządzenia ESP32. Kliknij ikonę filtra aby zobaczyć wszystkie.',
                      style: TextStyle(fontSize: 12, color: Colors.blue[700]),
                    ),
                  ),
                ],
              ),
            ),
          
          if (_isScanning)
            const LinearProgressIndicator(),
            
          Expanded(
            child: StreamBuilder<List<ScanResult>>(
              stream: _bleService.scanForDevices(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.bluetooth_searching, size: 64),
                        const SizedBox(height: 16),
                        Text(
                          'Wyszukiwanie urządzeń...',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  );
                }

                final allDevices = snapshot.data!;
                final filteredDevices = _filterDevices(allDevices);
                
                if (filteredDevices.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _showAllDevices ? Icons.bluetooth_disabled : Icons.search_off,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _showAllDevices 
                              ? 'Nie znaleziono urządzeń'
                              : 'Nie znaleziono urządzeń ESP32',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (!_showAllDevices)
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _showAllDevices = true;
                              });
                            },
                            icon: const Icon(Icons.filter_alt),
                            label: const Text('Pokaż wszystkie urządzenia'),
                          ),
                        if (_isScanning)
                          const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: Text(
                              'Nadal szukam...',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: ElevatedButton.icon(
                              onPressed: _startScan,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Skanuj ponownie'),
                            ),
                          ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    // Licznik znalezionych urządzeń
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        _showAllDevices
                            ? 'Znaleziono: ${filteredDevices.length} ${filteredDevices.length == 1 ? 'urządzenie' : 'urządzeń'}'
                            : 'Znaleziono: ${filteredDevices.length} ESP32',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filteredDevices.length,
                        itemBuilder: (context, index) {
                          final result = filteredDevices[index];
                          final device = result.device;
                          final rssi = result.rssi;
                          final isESP = _isESPDevice(device);
                          
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            elevation: isESP ? 2 : 1,
                            child: ListTile(
                              leading: Icon(
                                isESP ? Icons.developer_board : Icons.bluetooth,
                                color: isESP ? Colors.blue : Colors.grey,
                                size: isESP ? 32 : 24,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      device.platformName.isEmpty
                                          ? 'Nieznane urządzenie'
                                          : device.platformName,
                                      style: TextStyle(
                                        fontWeight: isESP ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  if (isESP)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.green,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Text(
                                        'ESP32',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Text(device.remoteId.toString()),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _getSignalIcon(rssi),
                                    color: _getSignalColor(rssi),
                                  ),
                                  Text('$rssi dBm', style: const TextStyle(fontSize: 10)),
                                ],
                              ),
                              onTap: () => _connectToDevice(device),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _getSignalIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_cellular_4_bar;
    if (rssi >= -70) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  Color _getSignalColor(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }

  @override
  void dispose() {
    _bleService.stopScan();
    super.dispose();
  }
}