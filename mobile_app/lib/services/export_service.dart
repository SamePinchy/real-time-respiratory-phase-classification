import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

// Hide symbols that conflict with flutter/material.dart
import 'package:excel/excel.dart' hide TextSpan;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/breath_data_model.dart';

enum ExportFormat { txt, xlsx, png }

// ── Internal phase-stat holder ────────────────────────────────────────────────

class _PhaseStat {
  final int count;
  final double totalSec;
  final double avgSec;
  final double minSec;
  final double maxSec;
  final double pct;

  const _PhaseStat({
    required this.count,
    required this.totalSec,
    required this.avgSec,
    required this.minSec,
    required this.maxSec,
    required this.pct,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class ExportService {
  static const ExportService _instance = ExportService._internal();
  factory ExportService() => _instance;
  const ExportService._internal();

  // ── Public entry point ─────────────────────────────────────────────────────

  Future<void> exportSession(BreathSession session, ExportFormat format) async {
    final fileName = _buildFileName(session, format);
    final tempDir  = await getTemporaryDirectory();
    final file     = File('${tempDir.path}/$fileName');

    switch (format) {
      case ExportFormat.txt:  await _writeTxt(file, session);
      case ExportFormat.xlsx: await _writeXlsx(file, session);
      case ExportFormat.png:  await _writePng(file, session);
    }

    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Dane sesji oddechowej — ${_sessionLabel(session)}',
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  String _buildFileName(BreathSession session, ExportFormat format) {
    final dt  = DateFormat('yyyy-MM-dd_HH-mm').format(session.startTime);
    final ext = switch (format) {
      ExportFormat.txt  => 'txt',
      ExportFormat.xlsx => 'xlsx',
      ExportFormat.png  => 'png',
    };
    return 'breath_$dt.$ext';
  }

  String _sessionLabel(BreathSession s) =>
      DateFormat('dd.MM.yyyy HH:mm').format(s.startTime);

  String _phaseLabel(int idx) => switch (idx) {
    0 => 'Wdech',
    1 => 'Wydech',
    2 => 'Zatrzymanie (wdech)',
    3 => 'Zatrzymanie (wydech)',
    _ => '—',
  };

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Phase breakdown (shared by xlsx + png) ─────────────────────────────────

  Map<int, _PhaseStat> _phaseBreakdown(BreathSession session) {
    final indices = session.phaseIndices;
    final data    = session.data;
    if (indices.isEmpty || indices.length != data.length) return {};

    final segs = <int, List<double>>{};
    int i = 0;
    while (i < indices.length) {
      final p = indices[i];
      int j = i + 1;
      while (j < indices.length && indices[j] == p) j++;
      if (p != 4) {
        // Koniec segmentu = początek kolejnego (eliminuje luki)
        final endIdx = j < indices.length ? j : j - 1;
        final dur = data[endIdx].timestamp
                .difference(data[i].timestamp)
                .inMilliseconds /
            1000.0;
        if (dur > 0) segs.putIfAbsent(p, () => []).add(dur);
      }
      i = j;
    }

    // Mianownik = suma sklasyfikowanych faz → procenty sumują się do 100 %
    double classifiedSec = 0;
    final totals = segs.map((p, durs) =>
        MapEntry(p, durs.fold(0.0, (a, b) => a + b)));
    totals.forEach((_, t) => classifiedSec += t);

    return segs.map((p, durs) {
      final total = totals[p]!;
      return MapEntry(
        p,
        _PhaseStat(
          count:    durs.length,
          totalSec: total,
          avgSec:   total / durs.length,
          minSec:   durs.reduce(math.min),
          maxSec:   durs.reduce(math.max),
          pct:      classifiedSec > 0 ? total / classifiedSec * 100 : 0,
        ),
      );
    });
  }

  // ── SNR (shared by xlsx + png) ─────────────────────────────────────────────

  double _computeSNR(BreathSession session) {
    final data = session.data;
    if (data.length < 30) return double.nan;

    final values  = data.map((d) => d.stretch).toList();
    final n       = values.length;
    final totalMs = data.last.timestamp.difference(data.first.timestamp).inMilliseconds;
    final hz      = totalMs > 0 ? n / (totalMs / 1000.0) : 10.0;
    final half    = (hz / 2).round().clamp(2, 10);

    final smooth = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n - 1, i + half);
      double sum = 0;
      for (int k = lo; k <= hi; k++) sum += values[k];
      smooth[i] = sum / (hi - lo + 1);
    }

    double variance(List<double> lst) {
      final mean = lst.fold(0.0, (a, b) => a + b) / lst.length;
      return lst.fold(0.0, (a, v) => a + (v - mean) * (v - mean)) / lst.length;
    }

    final sigVar   = variance(smooth);
    final noiseVar = variance(List.generate(n, (i) => values[i] - smooth[i]));
    if (noiseVar <= 0) return 60.0;
    if (sigVar   <= 0) return 0.0;
    return 10 * math.log(sigVar / noiseVar) / math.ln10;
  }

  // ── TXT export ─────────────────────────────────────────────────────────────

  Future<void> _writeTxt(File file, BreathSession session) async {
    final buf   = StringBuffer();
    final dtFmt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

    buf.writeln('# Sesja oddechowa');
    buf.writeln('# Rozpoczęcie: ${dtFmt.format(session.startTime)}');
    if (session.endTime != null) {
      buf.writeln('# Zakończenie: ${dtFmt.format(session.endTime!)}');
    }
    buf.writeln('# Próbek: ${session.data.length}');
    buf.writeln('#');
    buf.writeln('Timestamp\tRaw\tStretch[%]\tPhase');

    final hasPhases = session.phaseIndices.length == session.data.length;
    for (int i = 0; i < session.data.length; i++) {
      final d = session.data[i];
      buf.writeln(
        '${dtFmt.format(d.timestamp)}\t'
        '${d.rawValue?.toStringAsFixed(0) ?? '—'}\t'
        '${d.stretch.toStringAsFixed(4)}\t'
        '${hasPhases ? _phaseLabel(session.phaseIndices[i]) : '—'}',
      );
    }

    await file.writeAsString(buf.toString(), flush: true);
  }

  // ── XLSX export ────────────────────────────────────────────────────────────

  Future<void> _writeXlsx(File file, BreathSession session) async {
    final xl        = Excel.createExcel();
    final dataSheet = xl['Dane'];
    xl.setDefaultSheet('Dane');

    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#DDEEFF'),
    );

    // Headers
    for (final entry in {
      0: 'Timestamp',
      1: 'Rozciągnięcie [%]',
      2: 'Faza',
    }.entries) {
      final c = dataSheet.cell(
        CellIndex.indexByColumnRow(columnIndex: entry.key, rowIndex: 0),
      );
      c.value      = TextCellValue(entry.value);
      c.cellStyle  = headerStyle;
    }

    final dtFmt     = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');
    final hasPhases = session.phaseIndices.length == session.data.length;

    for (int i = 0; i < session.data.length; i++) {
      final d   = session.data[i];
      final row = i + 1;
      dataSheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = TextCellValue(dtFmt.format(d.timestamp));
      dataSheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = DoubleCellValue(double.parse(d.stretch.toStringAsFixed(4)));
      dataSheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
          .value = TextCellValue(
              hasPhases ? _phaseLabel(session.phaseIndices[i]) : '—');
    }

    dataSheet.setColumnWidth(0, 26);
    dataSheet.setColumnWidth(1, 18);
    dataSheet.setColumnWidth(2, 24);

    // Summary sheet
    final sumSheet = xl['Podsumowanie'];
    void addRow(int row, String label, String value) {
      sumSheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = TextCellValue(label);
      sumSheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = TextCellValue(value);
    }

    addRow(0, 'Sesja',         _sessionLabel(session));
    addRow(1, 'Czas trwania',  _fmtDuration(session.duration));
    addRow(2, 'Liczba próbek', session.data.length.toString());
    addRow(3, 'Liczba cykli',  session.totalCycles.toString());
    addRow(4, 'Rytm oddechu',
        '${session.averageBreathRate.toStringAsFixed(1)} /min');

    if (hasPhases) {
      int row = 6;
      addRow(row++, '── Czas w fazie ──', '');
      final bd = _phaseBreakdown(session);
      for (int p = 0; p < 4; p++) {
        final s = bd[p];
        if (s == null) continue;
        addRow(row++, _phaseLabel(p), '${s.totalSec.toStringAsFixed(1)} s');
      }
    }

    sumSheet.setColumnWidth(0, 28);
    sumSheet.setColumnWidth(1, 20);

    final bytes = xl.encode();
    if (bytes == null) throw Exception('Nie można zakodować XLSX');
    await file.writeAsBytes(bytes, flush: true);
  }

  // ── PNG export ─────────────────────────────────────────────────────────────

  static const double _W   = 800;
  static const double _pad = 36;
  static const double _cW  = _W - 2 * _pad;

  static const _phaseColors = [
    Color(0xFF4FC3F7), // inhale
    Color(0xFFEF9A9A), // exhale
    Color(0xFFA5D6A7), // retentionInhale
    Color(0xFFFFE082), // retentionExhale
  ];
  static const _phaseNames = [
    'Wdech', 'Wydech', 'Zatrzymanie (wdech)', 'Zatrzymanie (wydech)',
  ];

  Future<void> _writePng(File file, BreathSession session) async {
    final hasPhases = session.phaseIndices.length == session.data.length;
    final breakdown = hasPhases ? _phaseBreakdown(session) : <int, _PhaseStat>{};
    final snr       = _computeSNR(session);
    final phaseRows = [0, 1, 2, 3].where((p) => breakdown.containsKey(p)).length;

    // ── Total height ───────────────────────────────────────────────────────
    double h = 0;
    h += 90;                            // header
    h += 24;                            // gap
    h += 206;                           // stat grid
    h += 24;                            // gap
    if (phaseRows > 0) {
      h += 38;                          // section title
      h += 44;                          // table header
      h += phaseRows * 52.0;            // table rows
      h += 24;                          // gap
      h += 38;                          // pie title
      h += 280;                         // pie + legend
      h += 24;                          // gap
    }
    h += 38;                            // SNR title
    h += 130;                           // SNR card
    h += 24;                            // gap
    h += 50;                            // footer

    // ── Canvas ────────────────────────────────────────────────────────────
    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    double y       = 0;

    // Background
    canvas.drawRect(Rect.fromLTWH(0, 0, _W, h),
        Paint()..color = const Color(0xFFF5F7FA));

    // ── Header ────────────────────────────────────────────────────────────
    canvas.drawRect(Rect.fromLTWH(0, 0, _W, 90),
        Paint()..color = const Color(0xFF1565C0));
    canvas.drawRect(Rect.fromLTWH(0, 0, 6, 90),
        Paint()..color = const Color(0xFF42A5F5));
    _txt(canvas, 'Raport sesji oddechowej', Offset(_pad, 16),
        const TextStyle(color: Colors.white, fontSize: 22,
            fontWeight: FontWeight.bold));
    _txt(canvas, DateFormat('dd.MM.yyyy  HH:mm').format(session.startTime),
        Offset(_pad, 52),
        const TextStyle(color: Color(0xFFBBDEFB), fontSize: 15));
    y = 90 + 24;

    // ── Stats grid ─────────────────────────────────────────────────────────
    final dur    = session.duration;
    final cycleT = session.totalCycles > 0
        ? '${(dur.inMilliseconds / 1000.0 / session.totalCycles).toStringAsFixed(1)} s'
        : '—';
    final stats4 = [
      ('Czas trwania',   _fmtDuration(dur),
          const Color(0xFF1976D2)),
      ('Rytm oddechu',   '${session.averageBreathRate.toStringAsFixed(1)} /min',
          const Color(0xFF388E3C)),
      ('Liczba cykli',   hasPhases ? session.totalCycles.toString() : '—',
          const Color(0xFF00796B)),
      ('Śr. czas cyklu', cycleT,
          const Color(0xFF303F9F)),
    ];

    const boxW = (_cW - 16) / 2;
    const boxH = 90.0;
    for (int i = 0; i < 4; i++) {
      final col = i % 2;
      final row = i ~/ 2;
      _statBox(
        canvas,
        Rect.fromLTWH(_pad + col * (boxW + 16), y + row * (boxH + 16), boxW, boxH),
        stats4[i].$1, stats4[i].$2, stats4[i].$3,
      );
    }
    y += 206 + 24;

    // ── Phase table ─────────────────────────────────────────────────────────
    if (phaseRows > 0) {
      _sectionTitle(canvas, 'Analiza faz oddechu', Offset(_pad, y));
      y += 38;
      _tableHeader(canvas, y);
      y += 44;
      for (final p in [0, 1, 2, 3]) {
        final s = breakdown[p];
        if (s == null) continue;
        _tableRow(canvas, y, p, s);
        y += 52;
      }
      y += 24;

      // ── Pie chart ────────────────────────────────────────────────────────
      _sectionTitle(canvas, 'Rozkład faz', Offset(_pad, y));
      y += 38;
      _pieChart(canvas, Offset(_W / 2, y + 110), 100, breakdown);
      _pieLegend(canvas, y + 232, breakdown);
      y += 280 + 24;
    }

    // ── SNR ───────────────────────────────────────────────────────────────
    _sectionTitle(canvas, 'Jakość sygnału (SNR)', Offset(_pad, y));
    y += 38;
    _snrCard(canvas, Rect.fromLTWH(_pad, y, _cW, 130), snr);
    y += 130 + 24;

    // ── Footer ────────────────────────────────────────────────────────────
    final footerStyle = TextStyle(fontSize: 11, color: Colors.grey[500]);
    _txt(canvas,
        'Wygenerowano: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(DateTime.now())}',
        Offset(_pad, y + 12), footerStyle);
    _txtRight(canvas, 'Próbek: ${session.data.length}',
        Offset(_W - _pad, y + 12), footerStyle);

    // ── Encode ────────────────────────────────────────────────────────────
    final picture  = recorder.endRecording();
    final image    = await picture.toImage(_W.toInt(), h.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw Exception('Nie można zakodować PNG');
    await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
  }

  // ─────────────────────── Canvas drawing helpers ───────────────────────────

  void _txt(Canvas canvas, String text, Offset offset, TextStyle style,
      {double maxWidth = _cW}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, offset);
  }

  void _txtRight(Canvas canvas, String text, Offset rightEdge, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: _cW);
    tp.paint(canvas, Offset(rightEdge.dx - tp.width, rightEdge.dy));
  }

  void _sectionTitle(Canvas canvas, String title, Offset offset) {
    _txt(canvas, title, offset,
        const TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
            color: Color(0xFF37474F)));
  }

  void _card(Canvas canvas, Rect rect, {double radius = 10}) {
    // Shadow
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.translate(0, 2), Radius.circular(radius)),
      Paint()..color = const Color(0x22000000),
    );
    // Surface
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()..color = Colors.white,
    );
  }

  void _statBox(Canvas canvas, Rect rect, String label, String value, Color accent) {
    _card(canvas, rect);
    // Accent top bar
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(rect.left, rect.top, rect.width, 5),
        topLeft: const Radius.circular(10),
        topRight: const Radius.circular(10),
      ),
      Paint()..color = accent,
    );
    const lp = 14.0;
    _txt(canvas, label, Offset(rect.left + lp, rect.top + 16),
        TextStyle(fontSize: 12, color: Colors.grey[600]),
        maxWidth: rect.width - lp * 2);
    _txt(canvas, value, Offset(rect.left + lp, rect.top + 38),
        TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: accent),
        maxWidth: rect.width - lp * 2);
  }

  void _tableHeader(Canvas canvas, double y) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(_pad, y, _cW, 40), const Radius.circular(6)),
      Paint()..color = const Color(0xFFECEFF1),
    );
    final cols  = _tableColX();
    final hdrs  = ['Faza', 'Segm.', 'Śr. [s]', 'Min [s]', 'Maks [s]', '%'];
    final style = TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[700]);
    for (int i = 0; i < hdrs.length; i++) {
      _txt(canvas, hdrs[i], Offset(cols[i], y + 13), style, maxWidth: 60);
    }
  }

  void _tableRow(Canvas canvas, double y, int phaseIdx, _PhaseStat s) {
    if (phaseIdx.isEven) {
      canvas.drawRect(Rect.fromLTWH(_pad, y, _cW, 48),
          Paint()..color = const Color(0xFFFAFAFA));
    }
    // Color indicator
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(_pad, y + 10, 4, 28), const Radius.circular(2)),
      Paint()..color = _phaseColors[phaseIdx],
    );
    final cols  = _tableColX();
    final style = const TextStyle(fontSize: 12, color: Color(0xFF37474F));
    _txt(canvas, _phaseNames[phaseIdx], Offset(cols[0], y + 16), style, maxWidth: 155);
    _txt(canvas, s.count.toString(),           Offset(cols[1], y + 16), style, maxWidth: 55);
    _txt(canvas, s.avgSec.toStringAsFixed(1),  Offset(cols[2], y + 16), style, maxWidth: 55);
    _txt(canvas, s.minSec.toStringAsFixed(1),  Offset(cols[3], y + 16), style, maxWidth: 55);
    _txt(canvas, s.maxSec.toStringAsFixed(1),  Offset(cols[4], y + 16), style, maxWidth: 55);
    _txt(canvas, '${s.pct.toStringAsFixed(0)}%', Offset(cols[5], y + 16), style, maxWidth: 55);
    canvas.drawLine(Offset(_pad, y + 48), Offset(_pad + _cW, y + 48),
        Paint()..color = const Color(0xFFE0E0E0)..strokeWidth = 0.5);
  }

  List<double> _tableColX() => [
    _pad + 10, _pad + 175, _pad + 255, _pad + 345, _pad + 435, _pad + 520,
  ];

  void _pieChart(Canvas canvas, Offset center, double radius,
      Map<int, _PhaseStat> breakdown) {
    double startAngle = -math.pi / 2;
    final sep = Paint()
      ..color = const Color(0xFFF5F7FA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (int p = 0; p < 4; p++) {
      final s = breakdown[p];
      if (s == null || s.pct < 0.5) continue;
      final sweep = s.pct / 100 * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          startAngle, sweep, true, Paint()..color = _phaseColors[p]);
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          startAngle, sweep, true, sep);
      startAngle += sweep;
    }
    // Donut hole
    canvas.drawCircle(center, radius * 0.52,
        Paint()..color = const Color(0xFFF5F7FA));
  }

  void _pieLegend(Canvas canvas, double y, Map<int, _PhaseStat> breakdown) {
    final visible = [0, 1, 2, 3].where((p) => breakdown.containsKey(p)).toList();
    const itemW   = 180.0;
    final totalW  = visible.length * itemW;
    double x      = (_W - totalW) / 2;

    for (final p in visible) {
      final s = breakdown[p]!;
      canvas.drawCircle(Offset(x + 8, y + 7), 7, Paint()..color = _phaseColors[p]);
      _txt(canvas, '${_phaseNames[p]}  ${s.pct.toStringAsFixed(0)}%',
          Offset(x + 20, y),
          const TextStyle(fontSize: 12, color: Color(0xFF37474F)),
          maxWidth: itemW - 24);
      x += itemW;
    }
  }

  void _snrCard(Canvas canvas, Rect rect, double snr) {
    _card(canvas, rect);
    final (label, color, desc) = _snrQuality(snr);
    const lp = 20.0;

    _txt(canvas, snr.isNaN ? '—' : '${snr.toStringAsFixed(1)} dB',
        Offset(rect.left + lp, rect.top + 14),
        TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: color));

    // Badge
    const badgeH = 26.0;
    const badgeW = 120.0;
    final bx = rect.left + lp + 180;
    final by = rect.top + 20;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(bx, by, badgeW, badgeH), const Radius.circular(13)),
      Paint()..color = color,
    );
    _txt(canvas, label, Offset(bx + 10, by + 5),
        const TextStyle(color: Colors.white, fontSize: 13,
            fontWeight: FontWeight.w600),
        maxWidth: badgeW - 12);

    // Bar
    final barTop = rect.top + 64;
    const barH   = 10.0;
    final barW   = rect.width - lp * 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + lp, barTop, barW, barH),
          const Radius.circular(5)),
      Paint()..color = const Color(0xFFE0E0E0),
    );
    final fill = snr.isNaN ? 0.0 : (snr / 25.0).clamp(0.0, 1.0);
    if (fill > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.left + lp, barTop, barW * fill, barH),
            const Radius.circular(5)),
        Paint()..color = color,
      );
    }

    // Scale labels
    final scaleStyle = TextStyle(fontSize: 10, color: Colors.grey[500]);
    _txt(canvas, '0 dB',   Offset(rect.left + lp,              barTop + 16), scaleStyle);
    _txt(canvas, '10 dB',  Offset(rect.left + lp + barW * 0.4, barTop + 16), scaleStyle);
    _txt(canvas, '25+ dB', Offset(rect.left + lp + barW - 38,  barTop + 16), scaleStyle);

    // Description
    _txt(canvas, desc, Offset(rect.left + lp, barTop + 36),
        TextStyle(fontSize: 12, color: Colors.grey[600]),
        maxWidth: rect.width - lp * 2);
  }

  (String, Color, String) _snrQuality(double snr) {
    if (snr.isNaN) return ('Brak danych', Colors.grey,
        'Za krótka sesja do oceny sygnału.');
    if (snr >= 20) return ('Doskonały',   const Color(0xFF388E3C),
        'Sygnał bardzo czysty, minimalne zakłócenia.');
    if (snr >= 10) return ('Dobry',       const Color(0xFF7CB342),
        'Sygnał dobry z niewielkim szumem.');
    if (snr >=  3) return ('Umiarkowany', const Color(0xFFF57C00),
        'Widoczny szum — sprawdź mocowanie pasa.');
    return           ('Zaszumiony',       const Color(0xFFD32F2F),
        'Duże zakłócenia, wyniki klasyfikacji mogą być niedokładne.');
  }
}
