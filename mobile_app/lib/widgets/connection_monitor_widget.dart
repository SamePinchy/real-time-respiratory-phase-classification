import 'package:flutter/material.dart';
import '../services/ble_service.dart';

/// Widget monitorujący jakość połączenia BLE
class ConnectionMonitorWidget extends StatelessWidget {
  final BLEService bleService;

  const ConnectionMonitorWidget({
    Key? key,
    required this.bleService,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.network_check, size: 20),
                SizedBox(width: 8),
                Text(
                  'Jakość połączenia',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Jakość sygnału (RSSI)
            StreamBuilder<ConnectionQuality>(
              stream: bleService.connectionQualityStream,
              initialData: ConnectionQuality.good,
              builder: (context, snapshot) {
                final quality = snapshot.data ?? ConnectionQuality.good;
                return _buildQualityIndicator(quality);
              },
            ),
            
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            
            // Statystyki transmisji
            StreamBuilder<TransmissionStatistics>(
              stream: bleService.statisticsStream,
              initialData: bleService.currentStatistics,
              builder: (context, snapshot) {
                final stats = snapshot.data ?? bleService.currentStatistics;
                return _buildStatistics(stats);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQualityIndicator(ConnectionQuality quality) {
    Color color;
    String label;
    IconData icon;
    int bars;

    switch (quality) {
      case ConnectionQuality.excellent:
        color = Colors.green;
        label = 'Doskonała';
        icon = Icons.signal_wifi_4_bar;
        bars = 4;
        break;
      case ConnectionQuality.good:
        color = Colors.lightGreen;
        label = 'Dobra';
        icon = Icons.signal_wifi_4_bar;
        bars = 3;
        break;
      case ConnectionQuality.fair:
        color = Colors.orange;
        label = 'Średnia';
        icon = Icons.signal_wifi_statusbar_4_bar;
        bars = 2;
        break;
      case ConnectionQuality.poor:
        color = Colors.red;
        label = 'Słaba';
        icon = Icons.signal_wifi_bad;
        bars = 1;
        break;
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: List.generate(4, (index) {
                  return Container(
                    width: 8,
                    height: 16 + (index * 4.0),
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: index < bars ? color : Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatistics(TransmissionStatistics stats) {
    final lossColor = stats.packetLossRate < 1 
        ? Colors.green 
        : stats.packetLossRate < 5 
            ? Colors.orange 
            : Colors.red;

    return Column(
      children: [
        _buildStatRow(
          'Odebrane pakiety:',
          stats.receivedPackets.toString(),
          Colors.blue,
        ),
        const SizedBox(height: 8),
        _buildStatRow(
          'Utracone pakiety:',
          stats.lostPackets.toString(),
          stats.lostPackets > 0 ? Colors.orange : Colors.green,
        ),
        const SizedBox(height: 8),
        _buildStatRow(
          'Uszkodzone pakiety:',
          stats.corruptedPackets.toString(),
          stats.corruptedPackets > 0 ? Colors.red : Colors.green,
        ),
        const SizedBox(height: 8),
        _buildStatRow(
          'Stopa strat:',
          '${stats.packetLossRate.toStringAsFixed(2)}%',
          lossColor,
        ),
        const SizedBox(height: 8),
        _buildStatRow(
          'Siła sygnału (RSSI):',
          '${stats.rssi} dBm',
          _getRSSIColor(stats.rssi),
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[700],
          ),
        ),
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

  Color _getRSSIColor(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -70) return Colors.lightGreen;
    if (rssi >= -80) return Colors.orange;
    return Colors.red;
  }
}

/// Kompaktowy wskaźnik jakości połączenia (do AppBar)
class CompactConnectionIndicator extends StatelessWidget {
  final BLEService bleService;

  const CompactConnectionIndicator({
    Key? key,
    required this.bleService,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionQuality>(
      stream: bleService.connectionQualityStream,
      initialData: ConnectionQuality.good,
      builder: (context, snapshot) {
        final quality = snapshot.data ?? ConnectionQuality.good;
        
        Color color;
        IconData icon;
        
        switch (quality) {
          case ConnectionQuality.excellent:
            color = Colors.green;
            icon = Icons.signal_cellular_alt;
            break;
          case ConnectionQuality.good:
            color = Colors.lightGreen;
            icon = Icons.signal_cellular_alt;
            break;
          case ConnectionQuality.fair:
            color = Colors.orange;
            icon = Icons.signal_cellular_alt_2_bar;
            break;
          case ConnectionQuality.poor:
            color = Colors.red;
            icon = Icons.signal_cellular_alt_1_bar;
            break;
        }
        
        return IconButton(
          icon: Icon(icon),
          color: color,
          tooltip: 'Jakość połączenia: ${_getQualityLabel(quality)}',
          onPressed: () {
            _showConnectionDetailsDialog(context);
          },
        );
      },
    );
  }

  String _getQualityLabel(ConnectionQuality quality) {
    switch (quality) {
      case ConnectionQuality.excellent:
        return 'Doskonała';
      case ConnectionQuality.good:
        return 'Dobra';
      case ConnectionQuality.fair:
        return 'Średnia';
      case ConnectionQuality.poor:
        return 'Słaba';
    }
  }

  void _showConnectionDetailsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Szczegóły połączenia'),
        content: ConnectionMonitorWidget(bleService: bleService),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }
}