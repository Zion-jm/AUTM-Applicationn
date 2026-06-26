import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../domain/models/sensor_data.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

enum _TimeRange { today, week, month }

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String _selectedSensor = 'temperature';
  _TimeRange _selectedRange = _TimeRange.today;
  SensorHistory? _history;
  bool _loading = true;
  String? _error;
  int? _tooltipIndex;

  static const _sensorOptions = [
    ('temperature', 'Temp'),
    ('humidity', 'Humidity'),
    ('light', 'Light'),
    ('moisture', 'Moisture'),
    ('ph', 'pH'),
    ('ec', 'EC'),
  ];

  static const _rangeOptions = [
    (_TimeRange.today, 'Today'),
    (_TimeRange.week, 'Week'),
    (_TimeRange.month, 'Month'),
  ];

  Duration get _fetchDuration => switch (_selectedRange) {
    _TimeRange.today => const Duration(hours: 24),
    _TimeRange.week => const Duration(days: 7),
    _TimeRange.month => const Duration(days: 30),
  };

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
      _tooltipIndex = null;
    });
    try {
      final state = context.read<AppState>();
      final history = await state.fetchHistory(
        _selectedSensor,
        duration: _fetchDuration,
      );
      setState(() {
        _history = history;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load history: $e';
        _loading = false;
      });
    }
  }

  List<SensorDataPoint> _filterPoints(List<SensorDataPoint> all) {
    if (all.isEmpty) return all;
    final now = DateTime.now();
    final cutoff = switch (_selectedRange) {
      _TimeRange.today => now.subtract(const Duration(hours: 24)),
      _TimeRange.week => now.subtract(const Duration(days: 7)),
      _TimeRange.month => now.subtract(const Duration(days: 30)),
    };
    final filtered = all.where((p) => p.time.isAfter(cutoff)).toList();
    return filtered.isNotEmpty ? filtered : all;
  }

  String get _rangeLabel => switch (_selectedRange) {
    _TimeRange.today => '24h trend',
    _TimeRange.week => '7-day trend',
    _TimeRange.month => '30-day trend',
  };

  // ── Predictive Alert Logic ─────────────────────────────────
  _PredictiveAlert? _computePredictiveAlert(
    List<SensorDataPoint> points,
    SensorReading reading,
  ) {
    if (points.length < 6) return null;

    // Use last 6 points for linear regression
    final recent = points.sublist(math.max(0, points.length - 12));
    final n = recent.length;

    // X = time index (0, 1, 2, ...), Y = value
    double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
    for (int i = 0; i < n; i++) {
      final x = i.toDouble();
      final y = recent[i].value;
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumXX += x * x;
    }

    final denom = n * sumXX - sumX * sumX;
    if (denom == 0) return null;

    final slope = (n * sumXY - sumX * sumY) / denom;
    final intercept = (sumY - slope * sumX) / n;

    // Predict value 2 hours out
    final avgInterval = _averageIntervalMinutes(recent);
    if (avgInterval <= 0) return null;

    final stepsAhead = (120 / avgInterval).round(); // 2 hours in steps
    final predictedValue = slope * (n + stepsAhead) + intercept;

    // Check if trending toward threshold
    final currentValue = recent.last.value;
    final isRising = slope > 0;
    final isFalling = slope < 0;

    if (isRising && predictedValue > reading.warningHigh && currentValue < reading.warningHigh) {
      final minutesToBreach = _estimateMinutesToThreshold(
        currentValue, reading.warningHigh, slope, avgInterval);
      return _PredictiveAlert(
        message: '${reading.label} trending toward high threshold',
        etaMinutes: minutesToBreach,
        isHigh: true,
        predictedValue: predictedValue,
      );
    }

    if (isFalling && predictedValue < reading.warningLow && currentValue > reading.warningLow) {
      final minutesToBreach = _estimateMinutesToThreshold(
        currentValue, reading.warningLow, slope, avgInterval);
      return _PredictiveAlert(
        message: '${reading.label} trending toward low threshold',
        etaMinutes: minutesToBreach,
        isHigh: false,
        predictedValue: predictedValue,
      );
    }

    return null;
  }

  double _averageIntervalMinutes(List<SensorDataPoint> points) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += points[i].time.difference(points[i - 1].time).inMinutes.abs();
    }
    return total / (points.length - 1);
  }

  int _estimateMinutesToThreshold(
    double current, double threshold, double slopePerStep, double intervalMinutes) {
    if (slopePerStep == 0) return 9999;
    final steps = ((threshold - current) / slopePerStep).abs();
    return (steps * intervalMinutes).round();
  }

  // ── Offline Detection ──────────────────────────────────────
  bool _isOffline(SensorReading reading) {
    return DateTime.now().difference(reading.timestamp).inMinutes > 15;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        backgroundColor: AppTheme.bg0,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.inkMid),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Analytics',
          style: GoogleFonts.montserrat(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            letterSpacing: -1,
            color: AppTheme.olive,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppTheme.divider),
        ),
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          // ── Guard: no sensor data yet ──────────────────────
          if (state.readings.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sensors_off_outlined,
                        color: AppTheme.inkFaint, size: 48),
                    SizedBox(height: 16),
                    Text(
                      'No sensor data yet',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Connect your greenhouse device to see analytics.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // Safe: readings is non-empty from here on
          final reading = state.readings.firstWhere(
            (r) => r.id == _selectedSensor,
            orElse: () => state.readings.first,
          );
          final history = _history ?? state.historyFor(_selectedSensor);
          final filtered = _filterPoints(history.points);
          final color = statusColor(reading.status);
          final isOffline = _isOffline(reading);
          final predictiveAlert = !_loading && filtered.length >= 6
              ? _computePredictiveAlert(filtered, reading)
              : null;

          return RefreshIndicator(
            onRefresh: _loadHistory,
            color: AppTheme.olive,
            backgroundColor: AppTheme.bg1,
            child: CustomScrollView(
              slivers: [
                // Sticky header: Time range + Sensor picker
                SliverToBoxAdapter(
                  child: Container(
                    color: AppTheme.bg0,
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                    child: Column(
                      children: [
                        _buildTimeRangePicker(),
                        const SizedBox(height: 12),
                        _buildSensorPicker(),
                      ],
                    ),
                  ),
                ),
                // Main content
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        if (_error != null)
                          _buildErrorCard()
                        else ...[
                          // Offline indicator
                          if (isOffline)
                            _buildOfflineBanner(),
                          const SizedBox(height: 16),
                          // Predictive alert
                          if (predictiveAlert != null)
                            _buildPredictiveAlertCard(predictiveAlert, color),
                          if (predictiveAlert != null)
                            const SizedBox(height: 16),
                          // Stats row (synced with tooltip)
                          _buildStatsRow(reading, filtered),
                          const SizedBox(height: 16),
                          if (_loading)
                            const SizedBox(
                              height: 180,
                              child: Center(child: CircularProgressIndicator()),
                            )
                          else if (filtered.isEmpty)
                            _buildEmptyState()
                          else if (filtered.length < 2)
                            _buildInsufficientDataCard()
                          else ...[
                            _buildChartCard(reading, filtered, color),
                            const SizedBox(height: 16),
                            _buildTimeInRangeCard(reading, filtered),
                            const SizedBox(height: 16),
                            _buildBreachEventsCard(reading, filtered),
                          ],
                          const SizedBox(height: 16),
                          _buildAllSensorsTable(state),
                          const SizedBox(height: 16),
                          _buildActionButtons(),
                          const SizedBox(height: 20),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Offline Banner ───────────────────────────────────────────
  Widget _buildOfflineBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.inkFaint.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.inkFaint.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off, color: AppTheme.inkFaint, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sensor offline — last reading may be stale',
              style: TextStyle(
                color: AppTheme.inkFaint,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Predictive Alert Card ─────────────────────────────────
  Widget _buildPredictiveAlertCard(_PredictiveAlert alert, Color color) {
    final alertColor = alert.isHigh ? AppTheme.statusAlert : AppTheme.statusWarning;
    final etaText = alert.etaMinutes < 60
        ? '${alert.etaMinutes}m'
        : '${(alert.etaMinutes / 60).round()}h';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: alertColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: alertColor.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: alertColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              alert.isHigh ? Icons.trending_up : Icons.trending_down,
              color: alertColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.message,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'May breach in ~$etaText (predicted: ${alert.predictedValue.toStringAsFixed(1)})',
                  style: TextStyle(
                    color: alertColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty State ──────────────────────────────────────────────
  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.insert_chart_outlined,
            color: AppTheme.inkFaint,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            'No data yet',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start monitoring to see trends and insights for this sensor.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _loadHistory,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.olive,
              side: BorderSide(color: AppTheme.olive.withOpacity(0.5)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Insufficient Data Card ─────────────────────────────────
  Widget _buildInsufficientDataCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        children: [
          Icon(Icons.show_chart, color: AppTheme.inkFaint, size: 40),
          const SizedBox(height: 12),
          Text(
            'Not enough data for chart',
            style: TextStyle(
              color: AppTheme.inkFaint,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Need at least 2 data points',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.alertSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.statusAlert.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: AppTheme.statusAlert, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(
                color: AppTheme.statusAlert,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: _loadHistory,
            child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRangePicker() {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: _rangeOptions.map((option) {
          final range = option.$1;
          final label = option.$2;
          final selected = range == _selectedRange;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (_selectedRange != range) {
                  setState(() => _selectedRange = range);
                  _loadHistory();
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.bg0 : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: selected
                      ? Border.all(color: AppTheme.borderLight)
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? AppTheme.ink : AppTheme.inkFaint,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSensorPicker() {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _sensorOptions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (id, label) = _sensorOptions[i];
          final selected = id == _selectedSensor;
          return GestureDetector(
            onTap: () {
              if (_selectedSensor != id) {
                setState(() {
                  _selectedSensor = id;
                  _loading = true;
                  _history = null;
                  _tooltipIndex = null;
                });
                _loadHistory();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? AppTheme.bg3 : AppTheme.bg1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? AppTheme.textSecondary.withOpacity(0.4)
                      : AppTheme.divider,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatsRow(
      SensorReading reading, List<SensorDataPoint> points) {
    // If tooltip is active, show tooltip point as "Selected" instead of "Current"
    final values = points.map((p) => p.value).toList();
    final avg = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a + b) / values.length;
    final min = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a < b ? a : b);
    final max = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a > b ? a : b);

    int minIndex = 0;
    int maxIndex = 0;
    if (values.isNotEmpty) {
      for (int i = 0; i < values.length; i++) {
        if (values[i] == min) minIndex = i;
        if (values[i] == max) maxIndex = i;
      }
    }

    double? trend;
    if (points.length >= 4) {
      final mid = points.length ~/ 2;
      final firstHalf = points.sublist(0, mid).map((p) => p.value).reduce((a, b) => a + b) / mid;
      final secondHalf = points.sublist(mid).map((p) => p.value).reduce((a, b) => a + b) / (points.length - mid);
      trend = ((secondHalf - firstHalf) / firstHalf) * 100;
    }

    // Sync with tooltip: if active, show tooltip value as "Selected"
    final bool tooltipActive = _tooltipIndex != null && _tooltipIndex! < points.length;
    final String currentLabel = tooltipActive ? 'Selected' : 'Current';
    final String currentValue = tooltipActive
        ? _fmt(points[_tooltipIndex!].value, reading.unit)
        : _fmt(reading.value, reading.unit);

    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: currentLabel,
            value: currentValue,
            subValue: null,
            highlight: tooltipActive,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            label: 'Average',
            value: _fmt(avg, reading.unit),
            subValue: trend != null ? '${trend >= 0 ? '+' : ''}${trend.toStringAsFixed(1)}%' : null,
            subColor: trend != null
                ? (trend >= 0 ? AppTheme.statusNormal : AppTheme.statusAlert)
                : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            label: 'Min',
            value: _fmt(min, reading.unit),
            subValue: points.isNotEmpty ? _timeFmt(points[minIndex].time) : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            label: 'Max',
            value: _fmt(max, reading.unit),
            subValue: points.isNotEmpty ? _timeFmt(points[maxIndex].time) : null,
          ),
        ),
      ],
    );
  }

  Widget _buildChartCard(
      SensorReading reading,
      List<SensorDataPoint> points,
      Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(reading.label,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              Text(_rangeLabel,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: Row(
              children: [
                _buildYAxisLabels(points),
                const SizedBox(width: 4),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) {
                          setState(() {
                            _tooltipIndex = _findClosestIndex(
                              details.localPosition.dx,
                              points,
                              constraints.maxWidth,
                            );
                          });
                        },
                        onHorizontalDragStart: (details) {
                          setState(() {
                            _tooltipIndex = _findClosestIndex(
                              details.localPosition.dx,
                              points,
                              constraints.maxWidth,
                            );
                          });
                        },
                        onHorizontalDragUpdate: (details) {
                          setState(() {
                            _tooltipIndex = _findClosestIndex(
                              details.localPosition.dx,
                              points,
                              constraints.maxWidth,
                            );
                          });
                        },
                        child: Stack(
                          children: [
                            CustomPaint(
                              painter: _AnalyticsChartPainter(
                                points: points,
                                color: color,
                                warningLow: reading.warningLow,
                                warningHigh: reading.warningHigh,
                                tooltipIndex: _tooltipIndex,
                              ),
                              size: Size.infinite,
                            ),
                            if (_tooltipIndex != null)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bg0.withOpacity(0.95),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppTheme.divider),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.1),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${points[_tooltipIndex!].value.toStringAsFixed(1)}${reading.unit}',
                                        style: TextStyle(
                                          color: color,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _timeFmt(points[_tooltipIndex!].time),
                                        style: const TextStyle(
                                          color: AppTheme.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
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
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                points.isNotEmpty ? _timeFmt(points.first.time) : '',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11),
              ),
              Text(
                '${points.length} readings',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11),
              ),
              const Text('Now',
                  style: TextStyle(
                      color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildYAxisLabels(List<SensorDataPoint> points) {
    if (points.isEmpty) return const SizedBox(width: 56);
    final values = points.map((p) => p.value).toList();
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = maxV - minV;
    final pad = range * 0.2;

    final top = maxV + pad;
    final bottom = minV - pad;
    final mid = (top + bottom) / 2;

    return SizedBox(
      width: 56,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _compactFmt(top),
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            _compactFmt(mid),
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            _compactFmt(bottom),
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _compactFmt(double v) {
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    if (v == v.toInt()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }

  Widget _buildTimeInRangeCard(
      SensorReading reading, List<SensorDataPoint> points) {
    if (points.isEmpty) return const SizedBox.shrink();

    final total = points.length;
    final normalCount = points.where((p) =>
        p.value >= reading.warningLow && p.value <= reading.warningHigh).length;
    final lowCount = points.where((p) => p.value < reading.warningLow).length;
    final highCount = points.where((p) => p.value > reading.warningHigh).length;

    final normalPct = (normalCount / total * 100).round();
    final lowPct = (lowCount / total * 100).round();
    final highPct = (highCount / total * 100).round();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Time in Range',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Row(
              children: [
                if (normalPct > 0)
                  Expanded(
                    flex: normalPct,
                    child: Container(
                      height: 8,
                      color: AppTheme.statusNormal,
                    ),
                  ),
                if (lowPct > 0)
                  Expanded(
                    flex: lowPct,
                    child: Container(
                      height: 8,
                      color: AppTheme.statusWarning,
                    ),
                  ),
                if (highPct > 0)
                  Expanded(
                    flex: highPct,
                    child: Container(
                      height: 8,
                      color: AppTheme.statusAlert,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _RangeLegend(
                color: AppTheme.statusNormal,
                label: 'Normal',
                value: '$normalPct%',
              ),
              const SizedBox(width: 16),
              _RangeLegend(
                color: AppTheme.statusWarning,
                label: 'Low',
                value: '$lowPct%',
              ),
              const SizedBox(width: 16),
              _RangeLegend(
                color: AppTheme.statusAlert,
                label: 'High',
                value: '$highPct%',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBreachEventsCard(
      SensorReading reading, List<SensorDataPoint> points) {
    if (points.isEmpty) return const SizedBox.shrink();

    final breaches = <_BreachEvent>[];
    _BreachEvent? current;

    for (final point in points) {
      final isLow = point.value < reading.warningLow;
      final isHigh = point.value > reading.warningHigh;

      if (!isLow && !isHigh) {
        if (current != null) {
          current.endTime = point.time;
          breaches.add(current);
          current = null;
        }
        continue;
      }

      if (current == null || current.isHigh != isHigh) {
        if (current != null) {
          current.endTime = point.time;
          breaches.add(current);
        }
        current = _BreachEvent(
          startTime: point.time,
          isHigh: isHigh,
          peakValue: point.value,
          limit: isHigh ? reading.warningHigh : reading.warningLow,
        );
      } else {
        if (isHigh && point.value > current.peakValue) {
          current.peakValue = point.value;
        } else if (!isHigh && point.value < current.peakValue) {
          current.peakValue = point.value;
        }
      }
    }

    if (current != null) {
      current.endTime = points.last.time;
      breaches.add(current);
    }

    if (breaches.isEmpty) return const SizedBox.shrink();

    final recentBreaches = breaches.length > 5
        ? breaches.sublist(breaches.length - 5)
        : breaches;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Threshold Events',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.statusAlert.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${breaches.length} total',
                  style: TextStyle(
                    color: AppTheme.statusAlert,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...recentBreaches.reversed.map((breach) => _BreachEventRow(
                breach: breach,
                unit: reading.unit,
              )),
        ],
      ),
    );
  }

  Widget _buildAllSensorsTable(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text('All sensors',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          ...state.readings.map((r) => _SensorTableRow(
            reading: r,
            isOffline: _isOffline(r),
          )),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.download_rounded,
            label: 'Export Data',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Export coming soon')),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionButton(
            icon: Icons.share_rounded,
            label: 'Share',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Share coming soon')),
              );
            },
          ),
        ),
      ],
    );
  }

  String _fmt(double v, String unit) {
    if (unit == 'lux') return '${v.round()}';
    if (unit == 'pH' || unit == 'mS/cm') return v.toStringAsFixed(2);
    return '${v.toStringAsFixed(1)} $unit';
  }

  String _timeFmt(DateTime t) {
    if (_selectedRange == _TimeRange.today) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}';
  }

  int _findClosestIndex(
      double dx, List<SensorDataPoint> points, double chartWidth) {
    if (points.length < 2) return 0;
    final segmentWidth = chartWidth / (points.length - 1);
    return (dx / segmentWidth).round().clamp(0, points.length - 1);
  }
}

// ── Predictive Alert Model ───────────────────────────────────
class _PredictiveAlert {
  final String message;
  final int etaMinutes;
  final bool isHigh;
  final double predictedValue;

  _PredictiveAlert({
    required this.message,
    required this.etaMinutes,
    required this.isHigh,
    required this.predictedValue,
  });
}

// ── Stat Card (with highlight option) ────────────────────────
class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subValue;
  final Color? subColor;
  final bool highlight;

  const _StatCard({
    required this.label,
    required this.value,
    this.subValue,
    this.subColor,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.olive.withOpacity(0.1) : AppTheme.bg2,
        borderRadius: BorderRadius.circular(12),
        border: highlight
            ? Border.all(color: AppTheme.olive.withOpacity(0.3))
            : null,
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  color: highlight ? AppTheme.olive : AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          if (subValue != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (subColor != null)
                  Icon(
                    subValue!.startsWith('+') ? Icons.arrow_upward : Icons.arrow_downward,
                    color: subColor,
                    size: 12,
                  ),
                Text(
                  subValue!,
                  style: TextStyle(
                    color: subColor ?? AppTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _RangeLegend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;

  const _RangeLegend({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _BreachEvent {
  DateTime startTime;
  DateTime? endTime;
  final bool isHigh;
  double peakValue;
  final double limit;

  _BreachEvent({
    required this.startTime,
    this.endTime,
    required this.isHigh,
    required this.peakValue,
    required this.limit,
  });
}

class _BreachEventRow extends StatelessWidget {
  final _BreachEvent breach;
  final String unit;

  const _BreachEventRow({
    required this.breach,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final color = breach.isHigh ? AppTheme.statusAlert : AppTheme.statusWarning;
    final icon = breach.isHigh ? Icons.arrow_upward : Icons.arrow_downward;
    final duration = breach.endTime != null
        ? breach.endTime!.difference(breach.startTime)
        : Duration.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  breach.isHigh ? 'High threshold exceeded' : 'Low threshold exceeded',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtTime(breach.startTime)} \u2022 Peak: ${breach.peakValue.toStringAsFixed(1)}$unit (limit: ${breach.limit.toStringAsFixed(1)}$unit)',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (duration.inMinutes > 0)
            Text(
              '${duration.inMinutes}m',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppTheme.textSecondary, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SensorTableRow extends StatelessWidget {
  final SensorReading reading;
  final bool isOffline;
  const _SensorTableRow({required this.reading, this.isOffline = false});

  @override
  Widget build(BuildContext context) {
    final color = isOffline ? AppTheme.inkFaint : statusColor(reading.status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          Expanded(
            child: Text(
              reading.label,
              style: TextStyle(
                color: isOffline ? AppTheme.inkFaint : AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
          if (isOffline)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.inkFaint.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Offline',
                style: TextStyle(
                  color: AppTheme.inkFaint,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            Text(
              _fmt(reading.value, reading.unit),
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }

  String _fmt(double v, String unit) {
    if (unit == 'lux') return '${v.round()} $unit';
    if (unit == 'pH' || unit == 'mS/cm')
      return '${v.toStringAsFixed(2)} $unit';
    return '${v.toStringAsFixed(1)} $unit';
  }
}

// ── Analytics Chart Painter (with data gap support) ────────
class _AnalyticsChartPainter extends CustomPainter {
  final List<SensorDataPoint> points;
  final Color color;
  final double warningLow;
  final double warningHigh;
  final int? tooltipIndex;

  _AnalyticsChartPainter({
    required this.points,
    required this.color,
    required this.warningLow,
    required this.warningHigh,
    this.tooltipIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final values = points.map((p) => p.value).toList();
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV) == 0 ? 1.0 : maxV - minV;
    final pad = range * 0.2;

    double nx(int i) => i / (points.length - 1) * size.width;
    double ny(double v) =>
        size.height - ((v - minV + pad) / (range + pad * 2)) * size.height;

    // Compute average interval to detect gaps
    final avgInterval = _averageInterval(points);
    final gapThreshold = avgInterval * 2.5; // Gap if > 2.5x average interval

    canvas.drawRect(
      Rect.fromLTRB(
        0,
        ny(warningHigh.clamp(minV - pad, maxV + pad)),
        size.width,
        ny(warningLow.clamp(minV - pad, maxV + pad)),
      ),
      Paint()
        ..color = AppTheme.statusNormal.withOpacity(0.05)
        ..style = PaintingStyle.fill,
    );

    final thresholdPaint = Paint()
      ..color = AppTheme.statusWarning.withOpacity(0.3)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    if (warningLow >= minV - pad && warningLow <= maxV + pad) {
      canvas.drawLine(
        Offset(0, ny(warningLow)),
        Offset(size.width, ny(warningLow)),
        thresholdPaint,
      );
    }

    if (warningHigh >= minV - pad && warningHigh <= maxV + pad) {
      canvas.drawLine(
        Offset(0, ny(warningHigh)),
        Offset(size.width, ny(warningHigh)),
        thresholdPaint,
      );
    }

    final guidePaint = Paint()
      ..color = AppTheme.divider.withOpacity(0.5)
      ..strokeWidth = 1;
    for (int i = 1; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guidePaint);
    }

    // Gradient fill
    final fillPath = Path()..moveTo(nx(0), size.height);
    for (int i = 0; i < points.length; i++) {
      fillPath.lineTo(nx(i), ny(points[i].value));
    }
    fillPath.lineTo(nx(points.length - 1), size.height);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.25), color.withOpacity(0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    // Draw line segments — solid for connected data, dashed for gaps
    final solidPaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final dashedPaint = Paint()
      ..color = color.withOpacity(0.3)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Build segments: list of (startIndex, endIndex, hasGap)
    final segments = <_LineSegment>[];
    int segStart = 0;
    for (int i = 1; i < points.length; i++) {
      final interval = points[i].time.difference(points[i - 1].time).inMinutes.abs();
      final hasGap = interval > gapThreshold;
      if (hasGap) {
        segments.add(_LineSegment(segStart, i - 1, false));
        segments.add(_LineSegment(i - 1, i, true));
        segStart = i;
      }
    }
    segments.add(_LineSegment(segStart, points.length - 1, false));

    // Draw solid segments
    for (final seg in segments.where((s) => !s.isGap)) {
      final path = Path()..moveTo(nx(seg.start), ny(points[seg.start].value));
      for (int i = seg.start + 1; i <= seg.end; i++) {
        path.lineTo(nx(i), ny(points[i].value));
      }
      canvas.drawPath(path, solidPaint);
    }

    // Draw dashed gap segments
    for (final seg in segments.where((s) => s.isGap)) {
      final p1 = Offset(nx(seg.start), ny(points[seg.start].value));
      final p2 = Offset(nx(seg.end), ny(points[seg.end].value));
      _drawDashedLine(canvas, p1, p2, dashedPaint);
    }

    // Last point dot
    canvas.drawCircle(
      Offset(nx(points.length - 1), ny(points.last.value)),
      4,
      Paint()..color = color,
    );

    // Tooltip highlight
    if (tooltipIndex != null) {
      final index = tooltipIndex!;
      final x = nx(index);
      final y = ny(points[index].value);

      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = color.withOpacity(0.3)
          ..strokeWidth = 1,
      );

      canvas.drawCircle(Offset(x, y), 6, Paint()..color = color);
      canvas.drawCircle(
        Offset(x, y),
        10,
        Paint()
          ..color = color.withOpacity(0.2)
          ..style = PaintingStyle.fill,
      );
    }
  }

  double _averageInterval(List<SensorDataPoint> points) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += points[i].time.difference(points[i - 1].time).inMinutes.abs();
    }
    return total / (points.length - 1);
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashWidth = 4.0;
    const dashSpace = 4.0;
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance == 0) return;

    final dirX = dx / distance;
    final dirY = dy / distance;
    final steps = (distance / (dashWidth + dashSpace)).floor();

    for (int i = 0; i < steps; i++) {
      final startX = p1.dx + dirX * i * (dashWidth + dashSpace);
      final startY = p1.dy + dirY * i * (dashWidth + dashSpace);
      final endX = startX + dirX * dashWidth;
      final endY = startY + dirY * dashWidth;
      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), paint);
    }
  }

  @override
  bool shouldRepaint(_AnalyticsChartPainter old) =>
      old.points != points ||
      old.color != color ||
      old.tooltipIndex != tooltipIndex;
}

class _LineSegment {
  final int start;
  final int end;
  final bool isGap;
  _LineSegment(this.start, this.end, this.isGap);
}
