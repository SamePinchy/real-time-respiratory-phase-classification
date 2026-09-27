import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/breath_provider.dart';
import '../widgets/breath_chart_widget.dart';
import '../widgets/stats_card_widget.dart';
import '../widgets/calibration_widget.dart';
import '../services/session_storage.dart';
import '../services/ble_service.dart';
import '../models/ble_protocol.dart';
import 'history_screen.dart';
import 'device_scan_screen.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({Key? key}) : super(key: key);

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  final _chartController = BreathChartController();
  bool _isAutoScrollActive = true;

  // ── Start / Stop button ────────────────────────────────────────────────────

  Widget _buildStartStopButton(BuildContext context, BreathProvider provider) {
    final isRecording = provider.isRecording;
    final isEnabled   = provider.isConnected;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isEnabled
            ? () {
                if (isRecording) {
                  provider.stopRecording();
                  _showSaveDialog(context, provider);
                } else {
                  setState(() => _isAutoScrollActive = true);
                  provider.startRecording();
                }
              }
            : null,
        icon: Icon(isRecording ? Icons.stop_circle_outlined : Icons.play_circle_outline),
        label: Text(
          isRecording ? 'ZATRZYMAJ NAGRYWANIE' : 'ROZPOCZNIJ NAGRYWANIE',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isRecording ? Colors.red : Colors.green,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  // ── Auto-scroll resume button ──────────────────────────────────────────────

  Widget _buildAutoScrollButton() {
    final isActive = _isAutoScrollActive;
    return AnimatedOpacity(
      opacity: isActive ? 0.35 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: FilledButton.tonalIcon(
        onPressed: isActive
            ? null
            : () {
                _chartController.resumeAutoScroll();
                setState(() => _isAutoScrollActive = true);
              },
        icon: const Icon(Icons.skip_next, size: 18),
        label: const Text('Auto-scroll', style: TextStyle(fontSize: 12)),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: Colors.blue.shade100,
          foregroundColor: Colors.blue.shade800,
        ),
      ),
    );
  }

  Future<void> _showSettingsDialog(BuildContext context, BreathProvider provider) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ustawienia transmisji'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Zaawansowane opcje protokołu BLE',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              
              // ============================================================
              // NOWE: Kompensacja dryfu bazowego
              // ============================================================
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.purple.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_fix_high, color: Colors.purple, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Kompensacja dryfu',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.purple,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Automatycznie koryguje przesunięcia wartości bazowej tensometrów do 20%',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Włącz kompensację'),
                      value: provider.bleService.driftCompensationEnabled,
                      onChanged: (value) {
                        provider.bleService.setDriftCompensationEnabled(value);
                        Navigator.pop(context);
                        _showSettingsDialog(context, provider);
                      },
                    ),
                    if (provider.bleService.driftCompensationEnabled) ...[
                      const Divider(),
                      StreamBuilder<DriftDiagnostics>(
                        stream: provider.bleService.driftDiagnosticsStream,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Text(
                              'Czekam na dane...',
                              style: TextStyle(fontSize: 11),
                            );
                          }
                          final diag = snapshot.data!;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDriftStatRow(
                                'Offset korekcyjny:',
                                '${diag.currentOffset >= 0 ? '+' : ''}${diag.currentOffset.toStringAsFixed(2)}%',
                                diag.currentOffset.abs() > 5 ? Colors.orange : Colors.green,
                              ),
                              const SizedBox(height: 4),
                              _buildDriftStatRow(
                                'Średnia minimów:',
                                '${diag.averageMinima.toStringAsFixed(1)}%',
                                Colors.blue,
                              ),
                              const SizedBox(height: 4),
                              _buildDriftStatRow(
                                'Wykrytych minimów:',
                                '${diag.detectedMinimaCount}',
                                Colors.grey,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                provider.bleService.resetDriftCompensation();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Kompensator dryfu zresetowany'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.restart_alt, size: 16),
                              label: const Text('Reset', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              
              SwitchListTile(
                title: const Text('Retransmisja pakietów'),
                subtitle: const Text('Automatycznie żądaj ponownego wysłania zgubionych pakietów'),
                value: provider.bleService.retransmissionEnabled,
                onChanged: (value) {
                  provider.bleService.setRetransmissionEnabled(value);
                  Navigator.pop(context);
                  _showSettingsDialog(context, provider);
                },
              ),
              SwitchListTile(
                title: const Text('Potwierdzenia ACK'),
                subtitle: const Text('Wysyłaj potwierdzenia odbioru do ESP32'),
                value: provider.bleService.ackEnabled,
                onChanged: (value) {
                  provider.bleService.setAckEnabled(value);
                  Navigator.pop(context);
                  _showSettingsDialog(context, provider);
                },
              ),
              SwitchListTile(
                title: const Text('Auto-reconnect'),
                subtitle: const Text('Automatycznie łącz ponownie po utracie połączenia'),
                value: provider.bleService.autoReconnectEnabled,
                onChanged: (value) {
                  provider.bleService.setAutoReconnectEnabled(value);
                  Navigator.pop(context);
                  _showSettingsDialog(context, provider);
                },
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.blue),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Wyłączenie tych opcji może poprawić wydajność, ale zwiększy ryzyko utraty danych',
                        style: TextStyle(fontSize: 11, color: Colors.blue),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zamknij'),
          ),
        ],
      ),
    );
  }
  
  static Widget _buildDriftStatRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Future<void> _showSaveDialog(BuildContext context, BreathProvider provider) async {
    final session = provider.currentSession;
    if (session == null) return;

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Zapisać sesję?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Czy chcesz zapisać tę sesję do historii?'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _buildDialogStat('Czas trwania:', _formatDuration(session.duration)),
                  const SizedBox(height: 8),
                  _buildDialogStat('Śr. tempo oddechu:', '${session.averageBreathRate.toStringAsFixed(1)}/min'),
                  const SizedBox(height: 8),
                  _buildDialogStat('Punkty danych:', session.data.length.toString()),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Odrzuć'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.save),
            label: const Text('Zapisz'),
          ),
        ],
      ),
    );

    if (shouldSave == true && context.mounted) {
      try {
        final storageService = SessionStorageService();
        await storageService.saveSession(session);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Sesja zapisana pomyślnie'),
                ],
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Błąd zapisu: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showCalibrationDialog(BuildContext context, BreathProvider provider) {
    showDialog(
      context: context,
      builder: (context) => CalibrationDialog(
        bleService: provider.bleService,
      ),
    );
  }

  void _showRawDataOverlay(BuildContext context, BreathProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.science, size: 24),
                  const SizedBox(width: 12),
                  const Text(
                    'Surowe dane z tensometru',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<double>(
                stream: provider.bleService.rawDataStream,
                builder: (context, snapshot) {
                  final calib = provider.bleService.calibration;
                  
                  if (!snapshot.hasData || calib == null) {
                    return const Center(
                      child: Text('Czekam na dane...'),
                    );
                  }
                  
                  final raw = snapshot.data!;
                  final diff = raw - calib.baseline;
                  
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildRawDataCard(
                          'Wartość surowa',
                          raw.toStringAsFixed(3),
                          Icons.straighten,
                          Colors.blue,
                        ),
                        const SizedBox(height: 12),
                        _buildRawDataCard(
                          'Różnica od baseline',
                          '${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(3)}',
                          Icons.compare_arrows,
                          diff >= 0 ? Colors.green : Colors.red,
                        ),
                        const SizedBox(height: 12),
                        _buildRawDataCard(
                          'Baseline',
                          calib.baseline.toStringAsFixed(3),
                          Icons.horizontal_rule,
                          Colors.grey,
                        ),
                        const SizedBox(height: 12),
                        _buildRawDataCard(
                          'Min (zakres)',
                          calib.min.toStringAsFixed(3),
                          Icons.arrow_downward,
                          Colors.orange,
                        ),
                        const SizedBox(height: 12),
                        _buildRawDataCard(
                          'Max (zakres)',
                          calib.max.toStringAsFixed(3),
                          Icons.arrow_upward,
                          Colors.purple,
                        ),
                        
                        // NOWE: Diagnostyka kompensacji dryfu
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(Icons.auto_fix_high, size: 20, color: Colors.purple),
                            const SizedBox(width: 8),
                            const Text(
                              'Kompensacja dryfu',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: provider.bleService.driftCompensationEnabled
                                    ? Colors.green.withOpacity(0.2)
                                    : Colors.grey.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                provider.bleService.driftCompensationEnabled ? 'WŁĄCZONA' : 'WYŁĄCZONA',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: provider.bleService.driftCompensationEnabled
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        StreamBuilder<DriftDiagnostics>(
                          stream: provider.bleService.driftDiagnosticsStream,
                          builder: (context, driftSnapshot) {
                            if (!driftSnapshot.hasData) {
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey[100],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'Czekam na dane diagnostyczne...',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            }
                            
                            final diag = driftSnapshot.data!;
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.purple.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.purple.withOpacity(0.3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildDiagRow('Offset korekcyjny:', 
                                    '${diag.currentOffset >= 0 ? '+' : ''}${diag.currentOffset.toStringAsFixed(2)}%'),
                                  const SizedBox(height: 4),
                                  _buildDiagRow('Docelowy offset:', 
                                    '${diag.targetOffset >= 0 ? '+' : ''}${diag.targetOffset.toStringAsFixed(2)}%'),
                                  const SizedBox(height: 4),
                                  _buildDiagRow('Średnia minimów:', 
                                    '${diag.averageMinima.toStringAsFixed(1)}%'),
                                  const SizedBox(height: 4),
                                  _buildDiagRow('Wykrytych minimów:', 
                                    '${diag.detectedMinimaCount}'),
                                  const SizedBox(height: 4),
                                  _buildDiagRow('Bieżące rozciągnięcie:', 
                                    '${diag.currentStretch.toStringAsFixed(1)}%'),
                                ],
                              ),
                            );
                          },
                        ),
                        
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 16),
                        const Text(
                          'Diagnostyka',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            provider.bleService.getFullDiagnostics(raw),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  static Widget _buildDiagRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  static Widget _buildRawDataCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildDialogStat(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  static String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BreathProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              provider.isTestMode ? 'Monitor Oddechu (DEMO)' : 'Monitor Oddechu',
            ),
            backgroundColor: provider.isTestMode ? Colors.orange : null,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Strona główna',
              onPressed: () async {
                // Jeśli trwa nagrywanie — zapytaj o potwierdzenie
                if (provider.isRecording) {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Przerwać nagrywanie?'),
                      content: const Text(
                          'Trwa nagrywanie. Cofnięcie zakończy sesję bez zapisu.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Anuluj'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Wróć'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true || !context.mounted) return;
                  provider.stopRecording();
                }
                if (!context.mounted) return;
                await provider.disconnect();
                if (context.mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const DeviceScanScreen()),
                  );
                }
              },
            ),
            actions: [
              // NOWY: Przycisk kalibracji
              if (!provider.isTestMode)
                IconButton(
                  icon: const Icon(Icons.tune),
                  onPressed: () => _showCalibrationDialog(context, provider),
                  tooltip: 'Kalibracja',
                ),
              
              // NOWY: Przycisk surowych danych
              if (!provider.isTestMode)
                StreamBuilder<CalibrationData?>(
                  stream: provider.bleService.calibrationStream,
                  initialData: provider.bleService.calibration,
                  builder: (context, snapshot) {
                    final hasCalib = snapshot.data != null;
                    return IconButton(
                      icon: const Icon(Icons.science),
                      onPressed: hasCalib 
                          ? () => _showRawDataOverlay(context, provider)
                          : null,
                      tooltip: hasCalib ? 'Surowe dane' : 'Czekam na kalibrację...',
                      color: hasCalib ? Colors.green : Colors.grey,
                    );
                  },
                ),
              
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _showSettingsDialog(context, provider),
                tooltip: 'Ustawienia',
              ),
              IconButton(
                icon: const Icon(Icons.history),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const HistoryScreen(),
                    ),
                  );
                },
                tooltip: 'Historia',
              ),
              IconButton(
                icon: const Icon(Icons.bluetooth_connected),
                color: provider.isConnected ? Colors.green : Colors.red,
                onPressed: () async {
                  final shouldDisconnect = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Rozłączyć?'),
                      content: const Text('Czy na pewno chcesz rozłączyć urządzenie?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Anuluj'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Rozłącz'),
                        ),
                      ],
                    ),
                  );

                  if (shouldDisconnect == true && context.mounted) {
                    await provider.disconnect();
                    
                    // Wróć do ekranu skanowania
                    if (context.mounted) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (context) => const DeviceScanScreen(),
                        ),
                      );
                    }
                  }
                },
              ),
            ],
          ),
          body: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              // Karty statystyk
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // ── Wskaźnik trybu testowego ──────────────────────────
                    if (provider.isTestMode) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.science, color: Colors.orange),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'TRYB TESTOWY - Dane symulowane',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildStartStopButton(context, provider),
                      const SizedBox(height: 16),
                    ],

                    // ── Start/Stop (BLE mode) — na samej górze ────────────
                    if (!provider.isTestMode) ...[
                      _buildStartStopButton(context, provider),
                      const SizedBox(height: 16),
                    ],
                    
                    // NOWY: Wskaźnik kalibracji
                    if (!provider.isTestMode &&
                        !provider.bleService.rawPayloadMode)
                      StreamBuilder<CalibrationData?>(
                        stream: provider.bleService.calibrationStream,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.yellow.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.yellow.shade700),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.warning, color: Colors.yellow.shade700),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Czekam na dane kalibracyjne z ESP32...',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          
                          final calib = snapshot.data!;
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Kalibracja: baseline=${calib.baseline.toStringAsFixed(2)}, '
                                    'zakres=[${calib.min.toStringAsFixed(2)} - ${calib.max.toStringAsFixed(2)}]',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.tune, size: 16),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _showCalibrationDialog(context, provider),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    
                    // NOWE: Wskaźnik kompensacji dryfu
                    if (!provider.isTestMode && provider.bleService.driftCompensationEnabled)
                      StreamBuilder<DriftDiagnostics>(
                        stream: provider.bleService.driftDiagnosticsStream,
                        builder: (context, snapshot) {
                          final offset = snapshot.hasData 
                              ? snapshot.data!.currentOffset 
                              : 0.0;
                          final minimaCount = snapshot.hasData 
                              ? snapshot.data!.detectedMinimaCount 
                              : 0;
                          
                          final isActive = offset.abs() > 0.5;
                          
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.purple.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.purple.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isActive ? Icons.auto_fix_high : Icons.auto_fix_off,
                                  color: Colors.purple,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isActive
                                        ? 'Korekcja dryfu: ${offset >= 0 ? '+' : ''}${offset.toStringAsFixed(1)}% (${minimaCount} minimów)'
                                        : 'Kompensacja dryfu aktywna (czekam na dane)',
                                    style: const TextStyle(fontSize: 11, color: Colors.purple),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    provider.bleService.resetDriftCompensation();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Kompensator zresetowany'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                  child: const Icon(
                                    Icons.restart_alt,
                                    size: 16,
                                    color: Colors.purple,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    
                    Row(
                      children: [
                        Expanded(
                          child: StatsCard(
                            title: 'Rytm oddechu',
                            value: '${provider.currentBreathRate.toStringAsFixed(1)}',
                            unit: '/min',
                            icon: Icons.air,
                            color: Colors.blue,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: StatsCard(
                            title: 'Czas nagrywania',
                            value: provider.currentSession != null
                                ? _formatDuration(provider.currentSession!.duration)
                                : '0:00',
                            unit: '',
                            icon: Icons.timer,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Tytuł wykresu + przycisk auto-scroll — zawsze widoczne
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Rozciągnięcie pasa',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (provider.isRecording)
                      _buildAutoScrollButton(),
                  ],
                ),
              ),

              // Wykres — stała wysokość, suwak dostępny po przewinięciu
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: BreathChart(
                  data: provider.realtimeData,
                  dataType: ChartDataType.stretch,
                  isRecording: provider.isRecording,
                  phases: provider.realtimePhases,
                  yMin: provider.chartYMin,
                  yMax: provider.chartYMax,
                  chartHeight: MediaQuery.of(context).size.height * 0.50,
                  controller: _chartController,
                  onAutoScrollChanged: (active) {
                    setState(() => _isAutoScrollActive = active);
                  },
                ),
              ),
              ],
            ),
          ),
        );
      },
    );
  }
}