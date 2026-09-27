import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/breath_data_model.dart';
import '../services/breathing_classifier.dart';
import '../services/cycle_detector.dart';

enum ChartDataType { stretch }

// ── Controller ────────────────────────────────────────────────────────────────
/// Allows the parent widget to imperatively control [BreathChart].
class BreathChartController {
  _BreathChartState? _state;

  /// Re-enable auto-scroll (same as the user dragging back to the latest data).
  void resumeAutoScroll() => _state?._resumeAutoScroll();

  void _attach(_BreathChartState state) => _state = state;
  void _detach() => _state = null;
}

// ── Widget ────────────────────────────────────────────────────────────────────
class BreathChart extends StatefulWidget {
  final List<BreathData>      data;
  final ChartDataType         dataType;
  final int                   displaySeconds;
  final bool                  isRecording;
  final List<BreathingPhase>? phases;
  final double?               yMin;
  final double?               yMax;
  /// Fixed height for the chart area. The widget sizes itself to this height
  /// plus whatever space the legend and slider need, so the parent does NOT
  /// need to wrap it in an [Expanded].
  final double                chartHeight;
  /// Optional controller — call [BreathChartController.resumeAutoScroll].
  final BreathChartController? controller;
  /// Called whenever auto-scroll is enabled (true) or paused (false).
  final ValueChanged<bool>?    onAutoScrollChanged;

  const BreathChart({
    Key? key,
    required this.data,
    required this.dataType,
    this.displaySeconds = 10,
    this.isRecording = true,
    this.phases,
    this.yMin,
    this.yMax,
    this.chartHeight = 350.0,
    this.controller,
    this.onAutoScrollChanged,
  }) : super(key: key);

  @override
  State<BreathChart> createState() => _BreathChartState();
}

class _BreathChartState extends State<BreathChart> {
  double _viewMinX = 0.0;
  double _viewMaxX = 10.0;
  double _totalDuration = 0.0;
  bool _isUserScrolling = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _initializeView();
  }

  @override
  void didUpdateWidget(BreathChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      widget.controller?._attach(this);
    }
    _didUpdateWidgetBody(oldWidget);
  }

  @override
  void dispose() {
    widget.controller?._detach();
    super.dispose();
  }

  /// Called by [BreathChartController.resumeAutoScroll].
  void _resumeAutoScroll() {
    if (!_isUserScrolling) return;
    setState(() => _isUserScrolling = false);
    widget.onAutoScrollChanged?.call(true);
  }

  void _initializeView() {
    if (widget.data.isNotEmpty) {
      _totalDuration = _getTotalDuration();
      
      if (_totalDuration > widget.displaySeconds) {
        if (widget.isRecording) {
          // Podczas nagrywania - pokaż najnowsze dane
          _viewMaxX = _totalDuration;
          _viewMinX = _totalDuration - widget.displaySeconds;
        } else {
          // W historii - pokaż od początku
          _viewMinX = 0.0;
          _viewMaxX = widget.displaySeconds.toDouble();
        }
      } else {
        _viewMinX = 0.0;
        _viewMaxX = widget.displaySeconds.toDouble();
      }
    }
  }
  
  void _didUpdateWidgetBody(BreathChart oldWidget) {
    // Oblicz całkowitą długość danych
    double newDuration = 0;
    if (widget.data.isNotEmpty) {
      newDuration = _getTotalDuration();
    }
    
    // DEBUG - usuń to po naprawie
    if (widget.isRecording && newDuration > 95 && newDuration != _totalDuration) {
      print('🔍 didUpdateWidget: oldDuration=$_totalDuration, newDuration=$newDuration, dataPoints=${widget.data.length}');
    }
    
    _totalDuration = newDuration;
    
    // Reset przy nowym pomiarze (gdy dane są bardzo krótkie)
    if (widget.isRecording && widget.data.length < 5) {
      _viewMinX = 0.0;
      _viewMaxX = widget.displaySeconds.toDouble();
      _isUserScrolling = false;
      return;
    }
    
    // NAPRAWIONE: Automatyczne przewijanie podczas nagrywania
    if (widget.isRecording && !_isUserScrolling) {
      if (_totalDuration > widget.displaySeconds) {
        // KLUCZOWA ZMIANA: Zawsze aktualizuj widok w trybie live
        double newViewMax = _totalDuration;
        double newViewMin = _totalDuration - widget.displaySeconds;
        
        // DEBUG
        if (_totalDuration > 95) {
          print('🎯 Updating view: $_viewMinX-$_viewMaxX → $newViewMin-$newViewMax');
        }
        
        // WAŻNE: Wywołaj setState tylko jeśli wartości się zmieniły
        if (_viewMaxX != newViewMax || _viewMinX != newViewMin) {
          setState(() {
            _viewMaxX = newViewMax;
            _viewMinX = newViewMin;
          });
        }
      } else {
        // Jeśli dane są krótsze niż okno - pokaż wszystko
        if (_viewMinX != 0.0 || _viewMaxX != widget.displaySeconds.toDouble()) {
          setState(() {
            _viewMinX = 0.0;
            _viewMaxX = widget.displaySeconds.toDouble();
          });
        }
      }
    }
    
    // Dla danych historycznych - inicjalizuj widok gdy dane się zmieniły
    if (!widget.isRecording && oldWidget.data.length != widget.data.length && widget.data.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _initializeView();
          });
        }
      });
    }
  }

  double _getTotalDuration() {
    if (widget.data.isEmpty) return 0;
    if (widget.data.length == 1) return 0;
    
    final first = widget.data.first.timestamp;
    final last = widget.data.last.timestamp;
    final duration = last.difference(first).inMilliseconds / 1000.0;
    
    // DEBUG
    if (duration > 95 && duration < 105) {
      print('📏 _getTotalDuration: first=${first.toIso8601String()}, last=${last.toIso8601String()}, duration=${duration}s');
    }
    
    return duration;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) {
      return _buildEmptyChart(context);
    }

    final spots = _generateSpots();
    final canScroll = _totalDuration > widget.displaySeconds;
    final (minY, maxY) = _yBounds();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.chartHeight,
          child: GestureDetector(
            onHorizontalDragStart: canScroll
                ? (_) {
                    setState(() => _isUserScrolling = true);
                    widget.onAutoScrollChanged?.call(false);
                  }
                : null,
            onHorizontalDragUpdate: canScroll
                ? (details) {
                    setState(() {
                      final double dragAmount = details.delta.dx * 0.05;
                      final double windowSize = _viewMaxX - _viewMinX;
                      
                      double newMinX = _viewMinX - dragAmount;
                      double newMaxX = _viewMaxX - dragAmount;
                      
                      // Ogranicz do dostępnego zakresu
                      if (newMinX < 0) {
                        newMinX = 0;
                        newMaxX = windowSize;
                      }
                      if (newMaxX > _totalDuration) {
                        newMaxX = _totalDuration;
                        newMinX = _totalDuration - windowSize;
                      }
                      
                      _viewMinX = newMinX;
                      _viewMaxX = newMaxX;
                    });
                  }
                : null,
            onHorizontalDragEnd: canScroll
                ? (_) {
                    if (widget.isRecording && _viewMaxX >= _totalDuration - 1) {
                      setState(() => _isUserScrolling = false);
                      widget.onAutoScrollChanged?.call(true);
                    }
                  }
                : null,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.2),
                    spreadRadius: 2,
                    blurRadius: 5,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: LineChart(
                duration: Duration.zero,
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: (maxY - minY) / 4,
                    verticalInterval: (_viewMaxX - _viewMinX) / 5,
                    getDrawingHorizontalLine: (value) {
                      return FlLine(
                        color: Colors.grey.withOpacity(0.2),
                        strokeWidth: 1,
                      );
                    },
                    getDrawingVerticalLine: (value) {
                      return FlLine(
                        color: Colors.grey.withOpacity(0.2),
                        strokeWidth: 1,
                      );
                    },
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: (_viewMaxX - _viewMinX) / 5,
                        getTitlesWidget: (value, meta) {
                          // NAPRAWIONE: Formatuj etykiety dynamicznie
                          return Text(
                            '${value.toInt()}s',
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        interval: (maxY - minY) / 4,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            '${value.toInt()}%',
                            style: const TextStyle(fontSize: 10),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                  minX: _viewMinX,
                  maxX: _viewMaxX,
                  minY: minY,
                  maxY: maxY,
                  clipData: FlClipData.all(),
                  rangeAnnotations: RangeAnnotations(
                    verticalRangeAnnotations: _buildPhaseAnnotations(),
                  ),
                  extraLinesData: ExtraLinesData(
                    verticalLines: _buildCycleLines(),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withOpacity(0.1),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    enabled: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          return LineTooltipItem(
                            '${spot.x.toStringAsFixed(1)}s\n${spot.y.toStringAsFixed(1)}%',
                            const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        
        // Legenda faz — widoczna tylko gdy mamy dane z klasyfikatora
        if (widget.phases != null && widget.phases!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6.0, left: 4.0, right: 4.0),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _legendItem(BreathingPhase.inhale),
                _legendItem(BreathingPhase.exhale),
                _legendItem(BreathingPhase.retentionInhale),
                _legendItem(BreathingPhase.retentionExhale),
              ],
            ),
          ),

        // Pasek przewijania - zawsze widoczny gdy można przewijać
        if (canScroll)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.swipe, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Przeciągnij wykres lub użyj suwaka',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: Slider(
                          value: _viewMinX.clamp(
                            0.0, 
                            (_totalDuration - widget.displaySeconds).clamp(0.0, double.infinity)
                          ),
                          min: 0,
                          max: (_totalDuration - widget.displaySeconds).clamp(0.0, double.infinity),
                          onChanged: (value) {
                            final wasScrolling = _isUserScrolling;
                            setState(() {
                              _isUserScrolling = true;
                              _viewMinX = value;
                              _viewMaxX = value + widget.displaySeconds;
                            });
                            if (!wasScrolling) {
                              widget.onAutoScrollChanged?.call(false);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_viewMinX.toInt()}-${_viewMaxX.toInt()}s',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                if (widget.isRecording && !_isUserScrolling)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Automatyczne przewijanie • ${_totalDuration.toInt()}s',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }


  // ── Y bounds with 10 % padding ───────────────────────────────────────────
  // Returns (minY, maxY) to pass to LineChartData.
  // If caller supplied yMin/yMax (from file stats or BLE expanding range),
  // adds 10 % padding (minimum 2 % absolute so flat signals still look ok).
  // Falls back to 0–100 when no range is known yet.
  (double, double) _yBounds() {
    final lo = widget.yMin;
    final hi = widget.yMax;
    if (lo == null || hi == null) return (0.0, 100.0);

    final pad = math.max((hi - lo) * 0.10, 2.0);
    return (lo - pad, hi + pad);
  }

  // ── Phase background annotations ─────────────────────────────────────────
  List<VerticalRangeAnnotation> _buildPhaseAnnotations() {
    final phases = widget.phases;
    if (phases == null || phases.isEmpty || widget.data.isEmpty) return [];
    if (phases.length != widget.data.length) return [];

    final firstTs = widget.data.first.timestamp;
    final annotations = <VerticalRangeAnnotation>[];

    double xOf(int idx) =>
        widget.data[idx].timestamp.difference(firstTs).inMilliseconds / 1000.0;

    int i = 0;
    while (i < widget.data.length) {
      final phase = phases[i];

      int j = i + 1;
      while (j < widget.data.length && phases[j] == phase) j++;

      if (phase != BreathingPhase.unknown) {
        final x1 = xOf(i);
        final x2 = xOf(j - 1);

        // Filter to visible window for performance; no clamping — let fl_chart clip
        if (x2 >= _viewMinX && x1 <= _viewMaxX) {
          annotations.add(VerticalRangeAnnotation(
            x1: x1,
            x2: x2,
            color: phase.color.withOpacity(0.3),
          ));
        }
      }
      i = j;
    }
    return annotations;
  }

  // ── Cycle start markers (vertical dashed lines + "#N Xs" labels) ─────────
  List<VerticalLine> _buildCycleLines() {
    final phases = widget.phases;
    if (phases == null || phases.isEmpty || widget.data.isEmpty) return [];
    if (phases.length != widget.data.length) return [];

    final firstTs = widget.data.first.timestamp;
    double xOf(int idx) =>
        widget.data[idx].timestamp.difference(firstTs).inMilliseconds / 1000.0;

    // Accepted cycle starts (shared rule, rejects the second stage of a
    // two-stage inhale — see cycle_detector.dart)
    final inhaleStarts = detectCycleStarts(
      length: phases.length,
      valueAt: (i) => widget.data[i].stretch,
      isInhaleAt: (i) => phases[i] == BreathingPhase.inhale,
    );
    if (inhaleStarts.isEmpty) return [];

    final lines = <VerticalLine>[];
    for (int c = 0; c < inhaleStarts.length; c++) {
      final startIdx = inhaleStarts[c];
      final xStart   = xOf(startIdx);

      // Only draw lines that fall within (or just outside) the visible window
      if (xStart < _viewMinX - 2 || xStart > _viewMaxX + 2) continue;

      // Cycle duration = distance to next inhale start (or to end of data)
      final xEnd = (c + 1 < inhaleStarts.length)
          ? xOf(inhaleStarts[c + 1])
          : xOf(widget.data.length - 1);
      final duration = xEnd - xStart;
      final labelText = '#${c + 1}  ${duration.toStringAsFixed(1)}s';

      lines.add(VerticalLine(
        x: xStart,
        color: Colors.black38,
        strokeWidth: 1.2,
        dashArray: [6, 5],
        label: VerticalLineLabel(
          show: true,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.only(bottom: 2, left: 3),
          style: const TextStyle(
            fontSize: 9,
            color: Colors.black54,
            fontWeight: FontWeight.w500,
          ),
          labelResolver: (_) => labelText,
        ),
      ));
    }
    return lines;
  }

  List<FlSpot> _generateSpots() {
    if (widget.data.isEmpty) return [];

    final firstTimestamp = widget.data.first.timestamp;
    
    return widget.data.map((d) {
      final x = d.timestamp.difference(firstTimestamp).inMilliseconds / 1000.0;
      final y = d.stretch;
      return FlSpot(x, y);
    }).toList();
  }

  Widget _legendItem(BreathingPhase phase) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 3,
          decoration: BoxDecoration(
            color: phase.color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          phase.displayName,
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildEmptyChart(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.show_chart,
              size: 48,
              color: Colors.grey,
            ),
            const SizedBox(height: 8),
            Text(
              'Brak danych',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Rozpocznij nagrywanie, aby zobaczyć wykres',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}