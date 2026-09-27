import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/breath_data_model.dart';
import '../services/breathing_classifier.dart';
import '../services/export_service.dart';
import '../widgets/breath_chart_widget.dart';
import '../widgets/stats_card_widget.dart';

// ── Phase segment stats ───────────────────────────────────────────────────────

class _SegmentStats {
  final int count;       // number of segments
  final double totalSec; // total time in this phase
  final double avgSec;   // average segment duration
  final double minSec;   // shortest segment
  final double maxSec;   // longest segment
  final double pct;      // % of session time

  const _SegmentStats({
    required this.count,
    required this.totalSec,
    required this.avgSec,
    required this.minSec,
    required this.maxSec,
    required this.pct,
  });
}

// ── Screen ────────────────────────────────────────────────────────────────────

class SessionDetailScreen extends StatefulWidget {
  final BreathSession session;
  const SessionDetailScreen({Key? key, required this.session}) : super(key: key);

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  BreathSession get session => widget.session;
  bool _exporting = false;

  // ── Export ─────────────────────────────────────────────────────────────────

  Future<void> _showExportDialog() async {
    final format = await showDialog<ExportFormat>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Eksportuj dane'),
        children: [
          _formatTile(ctx, ExportFormat.txt,
              icon: Icons.description_outlined,
              label: 'Plik TXT',
              sub: 'Tab-separated, otwiera w Notatniku / Excelu'),
          _formatTile(ctx, ExportFormat.xlsx,
              icon: Icons.table_chart_outlined,
              label: 'Arkusz XLSX',
              sub: 'Microsoft Excel — dane + podsumowanie'),
          _formatTile(ctx, ExportFormat.png,
              icon: Icons.image_outlined,
              label: 'Karta PNG',
              sub: 'Obraz z metrykami, analizą faz i SNR'),
        ],
      ),
    );
    if (format == null || !mounted) return;

    setState(() => _exporting = true);
    try {
      await ExportService().exportSession(session, format);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd eksportu: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _formatTile(BuildContext ctx, ExportFormat fmt,
      {required IconData icon, required String label, required String sub}) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(ctx, fmt),
      child: Row(children: [
        Icon(icon, size: 32, color: Colors.blueGrey),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(sub, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ]),
        ),
      ]),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmt(double v, {int decimals = 1}) => v.toStringAsFixed(decimals);

  double _getMinStretch() => session.data.isEmpty
      ? 0
      : session.data.map((d) => d.stretch).reduce(math.min);

  double _getMaxStretch() => session.data.isEmpty
      ? 0
      : session.data.map((d) => d.stretch).reduce(math.max);

  List<BreathingPhase>? _getPhases() {
    if (session.phaseIndices.isEmpty) return null;
    if (session.phaseIndices.length != session.data.length) return null;
    return session.phaseIndices.map(BreathingPhase.fromIndex).toList();
  }

  (double?, double?) _getYBounds() {
    if (session.data.isEmpty) return (null, null);
    final lo = _getMinStretch();
    final hi = _getMaxStretch();
    final pad = math.max((hi - lo) * 0.10, 2.0);
    return (lo - pad, hi + pad);
  }

  /// For each non-unknown phase: compute segment-level stats.
  Map<BreathingPhase, _SegmentStats> _computePhaseBreakdown() {
    final phases = _getPhases();
    if (phases == null || phases.isEmpty || session.data.length < 2) return {};

    final segments = <BreathingPhase, List<double>>{};

    int i = 0;
    while (i < phases.length) {
      final phase = phases[i];
      int j = i + 1;
      while (j < phases.length && phases[j] == phase) j++;

      if (phase != BreathingPhase.unknown) {
        // Użyj początku NASTĘPNEGO segmentu jako końca bieżącego — eliminuje
        // luki między segmentami i sprawia że czasy przylegają do siebie.
        final endIdx = j < phases.length ? j : j - 1;
        final dur = session.data[endIdx].timestamp
                .difference(session.data[i].timestamp)
                .inMilliseconds /
            1000.0;
        if (dur > 0) segments.putIfAbsent(phase, () => []).add(dur);
      }
      i = j;
    }

    // Suma czasu wszystkich sklasyfikowanych faz (bez unknown) jako mianownik
    // — dzięki temu procenty zawsze sumują się do 100 %.
    double classifiedSec = 0;
    final totals = <BreathingPhase, double>{};
    for (final entry in segments.entries) {
      final total = entry.value.fold(0.0, (a, b) => a + b);
      totals[entry.key] = total;
      classifiedSec += total;
    }

    final result = <BreathingPhase, _SegmentStats>{};
    for (final entry in segments.entries) {
      final durs = entry.value;
      final total = totals[entry.key]!;
      result[entry.key] = _SegmentStats(
        count: durs.length,
        totalSec: total,
        avgSec: total / durs.length,
        minSec: durs.reduce(math.min),
        maxSec: durs.reduce(math.max),
        pct: classifiedSec > 0 ? total / classifiedSec * 100 : 0,
      );
    }
    return result;
  }

  double _avgCycleDuration() {
    final cycles = session.totalCycles;
    if (cycles == 0) return 0;
    final totalSec = session.duration.inMilliseconds / 1000.0;
    return totalSec / cycles;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    final phases = _getPhases();
    final (yMin, yMax) = _getYBounds();
    final breakdown = _computePhaseBreakdown();
    final hasFases = phases != null && breakdown.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Szczegóły sesji'),
        actions: [
          if (_exporting)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.upload_file),
              onPressed: _showExportDialog,
              tooltip: 'Eksportuj dane',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Session info ─────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.calendar_today,
                        color: Theme.of(context).primaryColor),
                    const SizedBox(width: 8),
                    const Text('Informacje o sesji',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                  const Divider(height: 24),
                  _infoRow('Rozpoczęcie:', dateFormat.format(session.startTime)),
                  if (session.endTime != null) ...[
                    const SizedBox(height: 8),
                    _infoRow('Zakończenie:', dateFormat.format(session.endTime!)),
                  ],
                  const SizedBox(height: 8),
                  _infoRow('ID sesji:', session.id),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Top stats ────────────────────────────────────────────────────
          Row(children: [
            Expanded(
              child: StatsCard(
                title: 'Czas trwania',
                value: _formatDuration(session.duration),
                unit: '',
                icon: Icons.timer,
                color: Colors.blue,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: StatsCard(
                title: 'Rytm oddechu',
                value: _fmt(session.averageBreathRate),
                unit: '/min',
                icon: Icons.speed,
                color: Colors.green,
              ),
            ),
          ]),

          const SizedBox(height: 16),

          Row(children: [
            Expanded(
              child: StatsCard(
                title: 'Liczba cykli',
                value: hasFases ? session.totalCycles.toString() : '—',
                unit: '',
                icon: Icons.loop,
                color: Colors.teal,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: StatsCard(
                title: 'Śr. czas cyklu',
                value: hasFases ? _fmt(_avgCycleDuration()) : '—',
                unit: 's',
                icon: Icons.av_timer,
                color: Colors.indigo,
              ),
            ),
          ]),

          const SizedBox(height: 24),

          // ── Chart ────────────────────────────────────────────────────────
          const Text('Rozciągnięcie pasa',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          BreathChart(
            data: session.data,
            dataType: ChartDataType.stretch,
            isRecording: false,
            displaySeconds: 10,
            phases: phases,
            yMin: yMin,
            yMax: yMax,
            chartHeight: 320,
          ),

          const SizedBox(height: 24),

          // ── Phase breakdown ───────────────────────────────────────────────
          if (hasFases) ...[
            const Text('Analiza faz oddechu',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildPhaseBreakdownCard(breakdown),
            const SizedBox(height: 24),
          ],

          // ── Phase pie chart ───────────────────────────────────────────────
          if (hasFases) ...[
            const Text('Rozkład faz',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildPieCard(breakdown),
            const SizedBox(height: 24),
          ],

          // ── SNR ───────────────────────────────────────────────────────────
          const Text('Jakość sygnału',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _buildSNRCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── SNR computation & card ────────────────────────────────────────────────

  /// Signal-to-Noise Ratio in dB.
  ///
  /// Method: moving-average (window ≈ 1 s) separates the slow breathing
  /// waveform ("signal") from high-frequency residuals ("noise").
  /// SNR = 10 · log₁₀(Var(signal) / Var(noise))
  double _computeSNR() {
    if (session.data.length < 30) return double.nan;

    final values = session.data.map((d) => d.stretch).toList();
    final n = values.length;

    // Estimate sample rate from timestamps
    final totalMs = session.data.last.timestamp
        .difference(session.data.first.timestamp)
        .inMilliseconds;
    final hz = totalMs > 0 ? n / (totalMs / 1000.0) : 10.0;

    // Window ≈ 1 second, but at least 5 and at most 20 samples
    final half = (hz / 2).round().clamp(2, 10);

    // Causal moving average (symmetric)
    final smooth = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n - 1, i + half);
      double sum = 0;
      for (int k = lo; k <= hi; k++) sum += values[k];
      smooth[i] = sum / (hi - lo + 1);
    }

    // Variance helpers
    double variance(List<double> lst) {
      final mean = lst.fold(0.0, (a, b) => a + b) / lst.length;
      return lst.fold(0.0, (a, v) => a + (v - mean) * (v - mean)) / lst.length;
    }

    final sigVar   = variance(smooth);
    final noiseVar = variance(List.generate(n, (i) => values[i] - smooth[i]));

    if (noiseVar <= 0) return 60.0;   // essentially no noise
    if (sigVar   <= 0) return 0.0;    // flat signal

    return 10 * math.log(sigVar / noiseVar) / math.ln10;
  }

  ({String label, Color color, IconData icon, String desc}) _snrQuality(double snr) {
    if (snr.isNaN) {
      return (
        label: 'Brak danych',
        color: Colors.grey,
        icon: Icons.help_outline,
        desc: 'Za krótka sesja do oceny sygnału.',
      );
    }
    if (snr >= 20) {
      return (
        label: 'Doskonały',
        color: Colors.green,
        icon: Icons.signal_cellular_alt,
        desc: 'Sygnał bardzo czysty, minimalne zakłócenia.',
      );
    }
    if (snr >= 10) {
      return (
        label: 'Dobry',
        color: Colors.lightGreen,
        icon: Icons.signal_cellular_alt_2_bar,
        desc: 'Sygnał dobry z niewielkim szumem.',
      );
    }
    if (snr >= 3) {
      return (
        label: 'Umiarkowany',
        color: Colors.orange,
        icon: Icons.signal_cellular_alt_1_bar,
        desc: 'Widoczny szum — sprawdź mocowanie pasa.',
      );
    }
    return (
      label: 'Zaszumiony',
      color: Colors.red,
      icon: Icons.signal_cellular_off,
      desc: 'Duże zakłócenia, wyniki klasyfikacji mogą być niedokładne.',
    );
  }

  Widget _buildSNRCard() {
    final snr = _computeSNR();
    final q   = _snrQuality(snr);

    // Bar fill: map SNR 0–25 dB → 0–1
    final fill = snr.isNaN ? 0.0 : (snr / 25.0).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: big number + badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  snr.isNaN ? '—' : '${snr.toStringAsFixed(1)} dB',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: q.color,
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  avatar: Icon(q.icon, size: 16, color: Colors.white),
                  label: Text(
                    q.label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                  backgroundColor: q.color,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fill,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(q.color),
              ),
            ),
            const SizedBox(height: 6),
            // Scale labels
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('0 dB', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                Text('10 dB', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                Text('20+ dB', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
              ],
            ),
            const SizedBox(height: 12),
            // Description
            Text(
              q.desc,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const Divider(height: 20),
            // Method note
            Text(
              'Metoda: wariancja sygnału (śr. krocząca ~1s) / wariancja residuów.',
              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }

  // ── Phase breakdown card ───────────────────────────────────────────────────

  Widget _buildPhaseBreakdownCard(Map<BreathingPhase, _SegmentStats> bd) {
    // Display order
    final order = [
      BreathingPhase.inhale,
      BreathingPhase.exhale,
      BreathingPhase.retentionInhale,
      BreathingPhase.retentionExhale,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const SizedBox(width: 8),
                Expanded(
                    flex: 4,
                    child: Text('Faza',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600))),
                _hdrCell('Segm.'),
                _hdrCell('Śr.'),
                _hdrCell('Min'),
                _hdrCell('Maks'),
                _hdrCell('%'),
              ]),
            ),
            const Divider(height: 1),

            ...order.map((phase) {
              final s = bd[phase];
              if (s == null) return const SizedBox.shrink();
              return _phaseRow(phase, s);
            }),
          ],
        ),
      ),
    );
  }

  Widget _phaseRow(BreathingPhase phase, _SegmentStats s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        // Color indicator
        Container(
          width: 4,
          height: 36,
          decoration: BoxDecoration(
            color: phase.color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        // Phase name
        Expanded(
          flex: 4,
          child: Text(
            phase.displayName,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
        // Segments count
        _dataCell(s.count.toString()),
        // Avg duration
        _dataCell('${_fmt(s.avgSec)}s'),
        // Min
        _dataCell('${_fmt(s.minSec)}s'),
        // Max
        _dataCell('${_fmt(s.maxSec)}s'),
        // Percentage
        _dataCell('${_fmt(s.pct, decimals: 0)}%'),
      ]),
    );
  }

  Widget _hdrCell(String text) => Expanded(
        flex: 2,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600),
        ),
      );

  Widget _dataCell(String text) => Expanded(
        flex: 2,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      );

  // ── Pie chart card ─────────────────────────────────────────────────────────

  Widget _buildPieCard(Map<BreathingPhase, _SegmentStats> bd) {
    final order = [
      BreathingPhase.inhale,
      BreathingPhase.exhale,
      BreathingPhase.retentionInhale,
      BreathingPhase.retentionExhale,
    ];

    final sections = <PieChartSectionData>[];
    for (final phase in order) {
      final s = bd[phase];
      if (s == null || s.pct < 0.5) continue; // skip tiny slivers
      sections.add(PieChartSectionData(
        value: s.pct,
        color: phase.color,
        title: '${_fmt(s.pct, decimals: 0)}%',
        radius: 80,
        titleStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          shadows: [Shadow(blurRadius: 2, color: Colors.black45)],
        ),
      ));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Sample count
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.grain, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Text(
                  'Liczba próbek: ${session.data.length}',
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Pie chart
            SizedBox(
              height: 220,
              child: PieChart(
                PieChartData(
                  sections: sections,
                  centerSpaceRadius: 40,
                  sectionsSpace: 2,
                  pieTouchData: PieTouchData(enabled: false),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Legend
            Wrap(
              spacing: 16,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: order.map((phase) {
                final s = bd[phase];
                if (s == null) return const SizedBox.shrink();
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: phase.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      phase.displayName,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black87),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Shared row widgets ─────────────────────────────────────────────────────

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(label,
              style: TextStyle(color: Colors.grey[600], fontSize: 14)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w500, fontSize: 14)),
        ),
      ],
    );
  }

}
