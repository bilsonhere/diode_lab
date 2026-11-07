import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import 'supabase_config.dart';
import 'experiment_repository.dart';

import 'dart:math' as math;
import 'dart:async';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseConfig.initialize();
  try {
    final rows = await SupabaseConfig.client
        .from('experiment_readings')
        .select()
        .limit(1);

    debugPrint('SUPABASE CONNECTION OK. Rows: ${rows.length}');
  } catch (e) {
    debugPrint('SUPABASE CONNECTION ERROR: $e');
  }
  runApp(const DiodeLabApp());
}

// ============================================================
// APP
// ============================================================

class DiodeLabApp extends StatelessWidget {
  const DiodeLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DiodeLab Pro',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        fontFamily: 'SF Pro Display',
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ============================================================
// SPLASH SCREEN
// ============================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFEC4899)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.memory,
                  size: 60,
                  color: Color(0xFF6366F1),
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'DiodeLab Pro',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Interactive Electronics Laboratory',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 40),
              const CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DIODE PHYSICS MODEL
// ============================================================
//
// A simplified Shockley diode equation gives a smooth exponential knee:
//
//   I = Is * (exp(V / (n * Vt)) - 1)
//
// Once the diode voltage reaches the clamp voltage (cut-in voltage,
// ~0.7 V for silicon) it is held CONSTANT, and any extra supply
// voltage is dropped across the series resistor:
//
//   Vdiode = 0.7 V,  I = (Vin - 0.7) / R
//
// The two regions meet continuously, so there is no jump in the graph.

const double _kIs = 1.15e-5; // saturation current, mA
const double _kNVt = 0.052; // ideality factor * thermal voltage
const double _kClampVoltage = 0.7; // diode voltage stays here after cut-in

/// Forward current (mA) for a given forward voltage (V >= 0).
double forwardCurrentMa(double v) {
  if (v <= 0) {
    return 0;
  }
  final raw = _kIs * (math.exp(v / _kNVt) - 1);
  return raw.clamp(0.0, 500.0);
}

/// Reverse ("leakage") current magnitude (mA) for a given reverse
/// voltage magnitude (v >= 0). Returns a small, slowly-growing value
/// representing reverse saturation current - no avalanche breakdown
/// is modeled, matching the "keep it simple" scope for this project.
double reverseLeakageCurrentMa(double v) {
  if (v <= 0) {
    return 0.001;
  }
  return 0.001 + v * 0.00005;
}

// ============================================================
// SHARED EXPERIMENT DATA (forward & reverse kept separate)
// ============================================================

class Reading {
  final String? id;
  final double vin;
  final double voltage;
  final double current;
  final DateTime timestamp;

  Reading(this.voltage, this.current, {this.id, this.vin = 0})
    : timestamp = DateTime.now();
}

class ExperimentData {
  static final ExperimentData _instance = ExperimentData._internal();
  factory ExperimentData() => _instance;
  ExperimentData._internal();

  // Two fully separate observation tables - one per bias mode.
  final List<Reading> forwardReadings = [];
  final List<Reading> reverseReadings = [];

  // Live circuit state shared between the circuit widget and the
  // rest of the Experiment screen.
  bool isForwardBias = true;
  double liveVoltage = 0; // signed: positive for forward, negative for reverse
  double liveCurrent = 0; // signed to match liveVoltage's sign convention

  void addForwardReading(
    double voltage,
    double current, {
    String? id,
    double vin = 0,
  }) {
    forwardReadings.add(Reading(voltage, current, id: id, vin: vin));
  }

  void addReverseReading(
    double voltage,
    double current, {
    String? id,
    double vin = 0,
  }) {
    reverseReadings.add(Reading(voltage, current, id: id, vin: vin));
  }

  void deleteForwardReading(int index) {
    if (index >= 0 && index < forwardReadings.length) {
      forwardReadings.removeAt(index);
    }
  }

  void deleteReverseReading(int index) {
    if (index >= 0 && index < reverseReadings.length) {
      reverseReadings.removeAt(index);
    }
  }

  void clearForwardReadings() => forwardReadings.clear();
  void clearReverseReadings() => reverseReadings.clear();

  bool get hasAnyReadings =>
      forwardReadings.isNotEmpty || reverseReadings.isNotEmpty;

  int get totalReadings => forwardReadings.length + reverseReadings.length;

  // ---------- Forward stats ----------

  double get maxForwardVoltage {
    if (forwardReadings.isEmpty) {
      return 0;
    }
    return forwardReadings.map((r) => r.voltage).reduce(math.max);
  }

  double get maxForwardCurrent {
    if (forwardReadings.isEmpty) {
      return 0;
    }
    return forwardReadings.map((r) => r.current).reduce(math.max);
  }

  double get estimatedCutInVoltage {
    if (forwardReadings.length < 2) {
      return forwardReadings.isEmpty ? 0 : forwardReadings.first.voltage;
    }
    final sorted = [...forwardReadings]
      ..sort((a, b) => a.voltage.compareTo(b.voltage));
    for (int i = 0; i < sorted.length - 1; i++) {
      if (sorted[i].current < 1.0 && sorted[i + 1].current >= 1.0) {
        return sorted[i + 1].voltage;
      }
    }
    return sorted.first.voltage;
  }

  double get averageForwardCurrent {
    if (forwardReadings.isEmpty) {
      return 0;
    }
    return forwardReadings.map((r) => r.current).reduce((a, b) => a + b) /
        forwardReadings.length;
  }

  String get forwardRegionAssessment {
    if (forwardReadings.isEmpty) {
      return 'No data yet';
    }
    final maxI = maxForwardCurrent;
    if (maxI > 15) {
      return 'Strong conduction';
    }
    if (maxI > 3) {
      return 'Moderate conduction';
    }
    return 'Weak (near knee)';
  }

  // ---------- Reverse stats ----------

  double get maxReverseVoltageMag {
    if (reverseReadings.isEmpty) {
      return 0;
    }
    return reverseReadings.map((r) => r.voltage.abs()).reduce(math.max);
  }

  double get maxReverseCurrentMag {
    if (reverseReadings.isEmpty) {
      return 0;
    }
    return reverseReadings.map((r) => r.current.abs()).reduce(math.max);
  }

  double get averageReverseCurrent {
    if (reverseReadings.isEmpty) {
      return 0;
    }
    return reverseReadings.map((r) => r.current).reduce((a, b) => a + b) /
        reverseReadings.length;
  }

  // ---------- Combined stats (used on Home) ----------

  double get overallMaxVoltage =>
      math.max(maxForwardVoltage, maxReverseVoltageMag);
  double get overallMaxCurrent =>
      math.max(maxForwardCurrent, maxReverseCurrentMag);

  // ---------- Text summaries ----------

  String forwardObservationText() {
    if (forwardReadings.isEmpty) {
      return 'No forward-bias readings recorded yet.';
    }
    return '• Readings taken: ${forwardReadings.length}\n'
        '• Maximum diode voltage: ${maxForwardVoltage.toStringAsFixed(3)} V\n'
        '• Maximum current measured: ${maxForwardCurrent.toStringAsFixed(2)} mA\n'
        '• Estimated cut-in voltage: ${estimatedCutInVoltage.toStringAsFixed(2)} V\n'
        '• Average forward current: ${averageForwardCurrent.toStringAsFixed(2)} mA\n'
        '• Region: $forwardRegionAssessment';
  }

  String reverseObservationText() {
    if (reverseReadings.isEmpty) {
      return 'No reverse-bias readings recorded yet.';
    }
    return '• Readings taken: ${reverseReadings.length}\n'
        '• Maximum reverse voltage applied: ${maxReverseVoltageMag.toStringAsFixed(2)} V\n'
        '• Maximum reverse (leakage) current: ${maxReverseCurrentMag.toStringAsFixed(4)} mA\n'
        '• Average reverse current: ${averageReverseCurrent.toStringAsFixed(4)} mA\n'
        '• Breakdown: Not reached';
  }

  String getAnalysisConclusion() {
    if (!hasAnyReadings) {
      return 'No readings have been recorded yet. Use the Experiment screen '
          'to apply voltage in forward and reverse bias and record readings.';
    }
    return 'The PN junction diode exhibits rectifying behavior, conducting '
        'strongly under forward bias once the cut-in voltage '
        '(~${estimatedCutInVoltage.toStringAsFixed(2)} V) is crossed, while '
        'allowing only a small, nearly constant leakage current to flow '
        'under reverse bias. This confirms the diode acts as a '
        'unidirectional device.';
  }
}

// ============================================================
// HOME SCREEN
// ============================================================

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final experimentData = ExperimentData();
    final hasReadings = experimentData.hasAnyReadings;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF6366F1).withValues(alpha: 0.2),
                          const Color(0xFF8B5CF6).withValues(alpha: 0.2),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(
                      Icons.memory,
                      color: Color(0xFF6366F1),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DiodeLab Pro',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        Text(
                          'Interactive Electronics Laboratory',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: hasReadings
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          hasReadings ? Icons.check_circle : Icons.info,
                          size: 16,
                          color: hasReadings ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          hasReadings ? 'Active' : 'Ready',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: hasReadings ? Colors.green : Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Simple, focused hero card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 32,
                  horizontal: 20,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const Text(
                      'PN JUNCTION DIODE',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 18),
                    CustomPaint(
                      size: const Size(90, 40),
                      painter: _DiodeGlyphPainter(color: Colors.white),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'V-I Characteristics',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasReadings
                          ? '${experimentData.totalReadings} readings recorded'
                          : 'Experiment ready to begin',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              const Text(
                'LABORATORY',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8),
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _buildModuleCard(
                      icon: Icons.menu_book,
                      title: 'Theory',
                      subtitle: 'Learn the concepts',
                      color: const Color(0xFF7B1FA2),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const TheoryScreen(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildModuleCard(
                      icon: Icons.science,
                      title: 'Experiment',
                      subtitle: 'Simulate & measure',
                      color: const Color(0xFF10B981),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ExperimentScreen(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildModuleCard(
                      icon: Icons.show_chart,
                      title: 'V-I Graph',
                      subtitle: 'Forward & reverse',
                      color: const Color(0xFF1565C0),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const GraphScreen(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildModuleCard(
                      icon: Icons.analytics,
                      title: 'Analysis',
                      subtitle: 'Cut-in, leakage, etc.',
                      color: const Color(0xFFE65100),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AnalysisScreen(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildModuleCard(
                icon: Icons.quiz,
                title: 'Quiz',
                subtitle: 'Test your understanding',
                color: const Color(0xFFF59E0B),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const QuizScreen()),
                ),
                fullWidth: true,
              ),

              const SizedBox(height: 24),

              // Primary call to action
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ExperimentScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.bolt),
                  label: const Text(
                    'OPEN CIRCUIT SIMULATOR',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModuleCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    bool fullWidth = false,
  }) {
    final card = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: fullWidth ? double.infinity : null,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    color.withValues(alpha: 0.2),
                    color.withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return card;
  }
}

/// A small standard-symbol diode glyph (triangle + bar) used as a
/// decorative element on the Home screen hero card.
class _DiodeGlyphPainter extends CustomPainter {
  final Color color;
  _DiodeGlyphPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final wire = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final midY = size.height / 2;
    final triLeft = size.width * 0.38;
    final triRight = size.width * 0.58;
    final barX = triRight + 3;

    canvas.drawLine(Offset(0, midY), Offset(triLeft, midY), wire);
    final path = Path()
      ..moveTo(triLeft, midY - 14)
      ..lineTo(triLeft, midY + 14)
      ..lineTo(triRight, midY)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawLine(Offset(barX, midY - 14), Offset(barX, midY + 14), wire);
    canvas.drawLine(Offset(barX, midY), Offset(size.width, midY), wire);
  }

  @override
  bool shouldRepaint(covariant _DiodeGlyphPainter oldDelegate) => false;
}

// ============================================================
// EXPERIMENT SCREEN
// ============================================================

class ExperimentScreen extends StatefulWidget {
  const ExperimentScreen({super.key});

  @override
  State<ExperimentScreen> createState() => _ExperimentScreenState();
}

class _ExperimentScreenState extends State<ExperimentScreen> {
  final experimentData = ExperimentData();

  bool isForwardBias = true;
  double sliderValue = 0; // always a positive magnitude; sign applied per mode
  double current = 0; // signed to match mode

  double diodeVoltage = 0;

  // Assumed series resistor: 220 Ω.
  // With mA and kΩ, the voltage drop is I × R.
  static const double _seriesResistanceKOhm = 0.22;
  static const double _forwardMax = 5.0;
  static const double _reverseMax = 12;
  Timer? _animTimer;
  double _flowPhase = 0;

  @override
  void initState() {
    super.initState();
    _recalculate();
    _loadReadingsFromDatabase();
    _animTimer = Timer.periodic(const Duration(milliseconds: 60), (timer) {
      if (!mounted) return;
      setState(() {
        _flowPhase = (_flowPhase + 0.03) % 1.0;
      });
    });
  }

  Future<void> _clearCurrentReadings() async {
    final type = isForwardBias ? 'forward' : 'reverse';
    final label = isForwardBias ? 'forward' : 'reverse';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear readings?'),
        content: Text(
          'This permanently deletes all $label-bias readings '
          'from the shared database.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await ExperimentRepository.clearReadings(experimentType: type);

      if (!mounted) return;

      setState(() {
        if (isForwardBias) {
          experimentData.clearForwardReadings();
        } else {
          experimentData.clearReverseReadings();
        }
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cleared $label-bias readings.')));
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Clear failed: $e')));
    }
  }

  Future<void> _loadReadingsFromDatabase() async {
    try {
      final rows = await ExperimentRepository.fetchReadings();

      if (!mounted) return;

      setState(() {
        experimentData.forwardReadings.clear();
        experimentData.reverseReadings.clear();

        for (final row in rows) {
          final reading = Reading(
            (row['vout'] as num).toDouble(),
            (row['current_ma'] as num).toDouble(),
            id: row['id'].toString(),
            vin: (row['vin'] as num?)?.toDouble() ?? 0,
          );

          if (row['experiment_type'] == 'forward') {
            experimentData.forwardReadings.add(reading);
          } else {
            experimentData.reverseReadings.add(reading);
          }
        }
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load readings: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    super.dispose();
  }

  void _recalculate() {
    final vin = isForwardBias ? sliderValue : -sliderValue;

    if (isForwardBias) {
      // Find the diode voltage where diode current equals
      // the current through the series resistor.
      double low = 0;
      double high = sliderValue;

      for (int i = 0; i < 80; i++) {
        final mid = (low + high) / 2;
        final diodeCurrent = forwardCurrentMa(mid);
        final resistorCurrent = (sliderValue - mid) / _seriesResistanceKOhm;

        if (diodeCurrent > resistorCurrent) {
          high = mid;
        } else {
          low = mid;
        }
      }

      final solved = (low + high) / 2;

      if (solved >= _kClampVoltage) {
        // Past cut-in: diode voltage stays constant, the rest of the
        // supply voltage drops across the series resistor.
        diodeVoltage = _kClampVoltage;
        current = ((sliderValue - _kClampVoltage) / _seriesResistanceKOhm)
            .clamp(0.0, 500.0);
      } else {
        diodeVoltage = solved;
        current = forwardCurrentMa(diodeVoltage);
      }
    } else {
      // Reverse-bias leakage current is signed negative.
      current = -reverseLeakageCurrentMa(sliderValue);

      // Vin = Vout + I × R
      diodeVoltage = vin - current * _seriesResistanceKOhm;
    }

    experimentData.isForwardBias = isForwardBias;
    experimentData.liveVoltage = diodeVoltage;
    experimentData.liveCurrent = current;
  }

  void _setBias(bool forward) {
    setState(() {
      isForwardBias = forward;
      sliderValue = 0;
      _recalculate();
    });
  }

  Future<void> _recordReading() async {
    final vin = isForwardBias ? sliderValue : -sliderValue;
    final vout = diodeVoltage;
    final type = isForwardBias ? 'forward' : 'reverse';

    try {
      final id = await ExperimentRepository.saveReading(
        experimentType: type,
        vin: vin,
        vout: vout,
        currentMa: current,
      );

      if (!mounted) return;

      setState(() {
        if (isForwardBias) {
          experimentData.addForwardReading(vout, current, id: id, vin: vin);
        } else {
          experimentData.addReverseReading(vout, current, id: id, vin: vin);
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reading saved to PostgreSQL successfully.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Database save failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _deleteReading(int index) async {
    final readings = isForwardBias
        ? experimentData.forwardReadings
        : experimentData.reverseReadings;

    if (index < 0 || index >= readings.length) return;

    final reading = readings[index];

    if (reading.id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This reading has no database ID. Reload readings first.',
          ),
        ),
      );
      return;
    }

    try {
      await ExperimentRepository.deleteReading(reading.id!);

      if (!mounted) return;

      setState(() {
        if (isForwardBias) {
          experimentData.deleteForwardReading(index);
        } else {
          experimentData.deleteReverseReading(index);
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reading deleted from database.')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final readings = isForwardBias
        ? experimentData.forwardReadings
        : experimentData.reverseReadings;
    final modeColor = isForwardBias
        ? const Color(0xFF10B981)
        : const Color(0xFF8B5CF6);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Experiment'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear ${isForwardBias ? "forward" : "reverse"} readings',
            onPressed: readings.isEmpty ? null : _clearCurrentReadings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E293B), Color(0xFF334155)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'V-I CHARACTERISTICS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  const Text(
                    'PN JUNCTION DIODE',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _biasTab('FORWARD', Icons.arrow_forward, true),
                        _biasTab('REVERSE', Icons.arrow_back, false),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Circuit
            Container(
              height: 230,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: CustomPaint(
                painter: DiodeCircuitPainter(
                  isForwardBias: isForwardBias,
                  voltageMagnitude: sliderValue,
                  current: current,
                  flowPhase: _flowPhase,
                  diodeVoltage: diodeVoltage,
                ),
                child: const SizedBox.expand(),
              ),
            ),

            const SizedBox(height: 16),

            // Live bias status card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: modeColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: modeColor.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isForwardBias ? 'Forward Bias' : 'Reverse Bias',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: modeColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isForwardBias
                        ? (current > 0.5
                              ? 'Diode conducting'
                              : 'Below cut-in - minimal conduction')
                        : 'Reverse leakage',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _readoutTile(
                          label: 'Current (Ammeter)',
                          value:
                              '${current.toStringAsFixed(isForwardBias ? 2 : 4)} mA',
                          icon: Icons.speed,
                          color: modeColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _readoutTile(
                          label: 'Voltage (Voltmeter)',
                          value: '${diodeVoltage.toStringAsFixed(3)} V',
                          icon: Icons.electric_bolt,
                          color: modeColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _recordReading,
                      icon: const Icon(Icons.add_chart),
                      label: const Text('Record Reading'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: modeColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Voltage slider
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Supply Voltage',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                      Text(
                        '${sliderValue.toStringAsFixed(2)} V',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: modeColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: sliderValue,
                    min: 0,
                    max: isForwardBias ? _forwardMax : _reverseMax,
                    divisions: isForwardBias ? 100 : 120,
                    activeColor: modeColor,
                    onChanged: (value) {
                      setState(() {
                        sliderValue = value;
                        _recalculate();
                      });
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '0 V',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      Text(
                        '${isForwardBias ? _forwardMax : _reverseMax} V',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Observation table
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${isForwardBias ? "Forward" : "Reverse"} Observation Table',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                Text(
                  '${readings.length} readings',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (readings.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Center(
                  child: Text(
                    'No readings yet. Move the slider and tap "Record Reading".',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    // ---- Header row ----
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 14,
                      ),
                      decoration: const BoxDecoration(
                        color: Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: Text(
                              '#',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              'Vin (V)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              'Vdiode (V)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              'Current (mA)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          SizedBox(width: 32),
                        ],
                      ),
                    ),
                    // ---- Data rows ----
                    ...List.generate(readings.length, (index) {
                      final r = readings[index];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 14,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Colors.grey.shade100),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                r.vin.abs().toStringAsFixed(2),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                r.voltage.toStringAsFixed(3),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                r.current.toStringAsFixed(
                                  isForwardBias ? 2 : 4,
                                ),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.close,
                                  size: 16,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () => _deleteReading(index),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const GraphScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.show_chart),
                    label: const Text('View Graph'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AnalysisScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.analytics),
                    label: const Text('Analysis'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _biasTab(String label, IconData icon, bool forward) {
    final selected = isForwardBias == forward;
    final color = forward ? const Color(0xFF10B981) : const Color(0xFF8B5CF6);
    return GestureDetector(
      onTap: () => _setBias(forward),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: selected ? color : Colors.white70),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: selected ? color : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readoutTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CIRCUIT SCHEMATIC PAINTER
// Battery, resistor, ammeter (series), diode (triangle+bar) and a
// voltmeter wired in parallel across the diode, with animated
// current-flow particles.
// ============================================================

class DiodeCircuitPainter extends CustomPainter {
  final bool isForwardBias;
  final double voltageMagnitude; // supply (battery) voltage magnitude
  final double current; // signed
  final double flowPhase;
  final double diodeVoltage; // voltage across the diode (voltmeter reading)

  DiodeCircuitPainter({
    required this.isForwardBias,
    required this.voltageMagnitude,
    required this.current,
    required this.flowPhase,
    required this.diodeVoltage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final wire = Paint()
      ..color = const Color(0xFF64748B)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final component = Paint()
      ..color = const Color(0xFF334155)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final tp = TextPainter(textDirection: TextDirection.ltr);
    void drawLabel(
      String text,
      Offset offset, {
      Color color = const Color(0xFF334155),
      double size = 11,
      FontWeight weight = FontWeight.w600,
    }) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: weight),
      );
      tp.layout();
      tp.paint(canvas, offset);
    }

    final left = 26.0;
    final right = size.width - 26.0;
    final top = 60.0;
    final bottom = size.height - 40.0;
    final midY = (top + bottom) / 2;

    // ---- Positions of all components (declared up-front) ----
    final resStart = left + (right - left) * 0.10;
    final resEnd = left + (right - left) * 0.34;
    final ammeterCx = left + (right - left) * 0.50;
    final diodeStart = left + (right - left) * 0.66;
    final diodeEnd = left + (right - left) * 0.86;
    final triLeft = diodeStart;
    final triRight = diodeStart + (diodeEnd - diodeStart) * 0.6;
    final barX = triRight + 3;
    final vTop = top - 34;

    // ---- Main loop wires ----
    final battTop = midY - 16;
    final battBottom = midY + 12;
    canvas.drawLine(Offset(left, top), Offset(left, battTop), wire);
    canvas.drawLine(Offset(left, battBottom), Offset(left, bottom), wire);
    canvas.drawLine(Offset(right, top), Offset(right, bottom), wire);
    canvas.drawLine(Offset(left, bottom), Offset(right, bottom), wire);

    // ---- Battery symbol (drawn on the left vertical wire) ----
    final positiveOnTop = isForwardBias;
    canvas.drawLine(
      Offset(left - (positiveOnTop ? 11 : 6), battTop),
      Offset(left + (positiveOnTop ? 11 : 6), battTop),
      Paint()
        ..color = const Color(0xFF334155)
        ..strokeWidth = positiveOnTop ? 2.0 : 4.0,
    );
    canvas.drawLine(
      Offset(left - (positiveOnTop ? 6 : 11), battBottom),
      Offset(left + (positiveOnTop ? 6 : 11), battBottom),
      Paint()
        ..color = const Color(0xFF334155)
        ..strokeWidth = positiveOnTop ? 4.0 : 2.0,
    );
    drawLabel(
      positiveOnTop ? '+' : '-',
      Offset(left + 16, battTop - 9),
      color: const Color(0xFF10B981),
      size: 14,
      weight: FontWeight.bold,
    );
    drawLabel(
      positiveOnTop ? '-' : '+',
      Offset(left + 16, battBottom - 2),
      color: Colors.redAccent,
      size: 14,
      weight: FontWeight.bold,
    );
    // Battery label = supply voltage (Vin)
    drawLabel(
      '${(isForwardBias ? voltageMagnitude : -voltageMagnitude).toStringAsFixed(2)} V',
      Offset(left - 20, midY + 22),
      size: 10,
      color: Colors.grey.shade700,
    );

    // ---- Top wire with Resistor -> Ammeter -> Diode ----
    canvas.drawLine(Offset(left, top), Offset(resStart, top), wire);

    // Resistor zig-zag
    final zig = Path()..moveTo(resStart, top);
    final segments = 6;
    final segW = (resEnd - resStart) / segments;
    for (int i = 0; i < segments; i++) {
      final x = resStart + segW * (i + 1);
      final y = top + (i.isEven ? -8.0 : 8.0);
      zig.lineTo(x, i == segments - 1 ? top : y);
    }
    canvas.drawPath(zig, component);
    drawLabel(
      'R',
      Offset((resStart + resEnd) / 2 - 4, top - 26),
      size: 12,
      weight: FontWeight.bold,
    );

    canvas.drawLine(Offset(resEnd, top), Offset(ammeterCx - 16, top), wire);

    // Ammeter
    canvas.drawCircle(Offset(ammeterCx, top), 16, component);
    drawLabel(
      'A',
      Offset(ammeterCx - 5, top - 8),
      size: 13,
      weight: FontWeight.bold,
    );
    canvas.drawLine(Offset(ammeterCx + 16, top), Offset(diodeStart, top), wire);

    // Diode - filled triangle (anode) + bar (cathode).
    final diodeFill = Paint()
      ..color = isForwardBias
          ? const Color(0xFF10B981)
          : const Color(0xFF94A3B8)
      ..style = PaintingStyle.fill;
    final trianglePath = Path()
      ..moveTo(triLeft, top - 14)
      ..lineTo(triLeft, top + 14)
      ..lineTo(triRight, top)
      ..close();
    canvas.drawPath(trianglePath, diodeFill);
    canvas.drawPath(trianglePath, component);
    canvas.drawLine(
      Offset(barX, top - 14),
      Offset(barX, top + 14),
      component..strokeWidth = 3.5,
    );
    component.strokeWidth = 2.5;
    canvas.drawLine(Offset(barX, top), Offset(diodeEnd, top), wire);
    canvas.drawLine(Offset(diodeEnd, top), Offset(right, top), wire);
    drawLabel(
      'DIODE',
      Offset(diodeStart - 6, top + 22),
      size: 10,
      color: Colors.grey.shade700,
    );

    // ---- Voltmeter branch (parallel across the diode) ----
    canvas.drawLine(Offset(triLeft, top - 14), Offset(triLeft, vTop), wire);
    canvas.drawLine(Offset(barX, top - 14), Offset(barX, vTop), wire);
    canvas.drawLine(
      Offset(triLeft, vTop),
      Offset((triLeft + barX) / 2 - 14, vTop),
      wire,
    );
    canvas.drawLine(
      Offset((triLeft + barX) / 2 + 14, vTop),
      Offset(barX, vTop),
      wire,
    );
    canvas.drawCircle(Offset((triLeft + barX) / 2, vTop), 14, component);
    drawLabel(
      'V',
      Offset((triLeft + barX) / 2 - 4, vTop - 7),
      size: 12,
      weight: FontWeight.bold,
    );
    // Voltmeter label = voltage across the diode (matches the table)
    drawLabel(
      '${diodeVoltage.toStringAsFixed(3)} V',
      Offset((triLeft + barX) / 2 - 20, vTop - 26),
      size: 9,
      color: Colors.grey.shade600,
    );

    // ---- Current flow animation ----
    final flowing = current.abs() > 0.15;
    if (flowing) {
      final intensity = (current.abs() / (isForwardBias ? 20.0 : 0.01)).clamp(
        0.15,
        1.0,
      );
      final flowColor =
          (isForwardBias ? const Color(0xFF10B981) : const Color(0xFF8B5CF6))
              .withValues(alpha: 0.35 + 0.65 * intensity);
      final flowPaint = Paint()..color = flowColor;

      final loopPoints = <Offset>[
        Offset(left, top),
        Offset(resStart, top),
        Offset(resEnd, top),
        Offset(ammeterCx - 16, top),
        Offset(ammeterCx + 16, top),
        Offset(diodeStart, top),
        Offset(diodeEnd, top),
        Offset(right, top),
        Offset(right, bottom),
        Offset(left, bottom),
        Offset(left, battBottom),
      ];
      double totalLen = 0;
      final segLens = <double>[];
      for (int i = 0; i < loopPoints.length - 1; i++) {
        final d = (loopPoints[i + 1] - loopPoints[i]).distance;
        segLens.add(d);
        totalLen += d;
      }

      final dotCount = 10;
      for (int i = 0; i < dotCount; i++) {
        final progress = (flowPhase + i / dotCount) % 1.0;
        var dist = progress * totalLen;
        Offset pos = loopPoints.first;
        for (int s = 0; s < segLens.length; s++) {
          if (dist <= segLens[s]) {
            final t = segLens[s] == 0 ? 0.0 : dist / segLens[s];
            pos = Offset.lerp(loopPoints[s], loopPoints[s + 1], t)!;
            break;
          }
          dist -= segLens[s];
        }
        canvas.drawCircle(pos, 2.5 + 1.5 * intensity, flowPaint);
      }
    }

    // ---- Status caption ----
    drawLabel(
      isForwardBias
          ? (flowing ? 'Diode conducting' : 'Below cut-in')
          : 'Reverse leakage (~${current.abs().toStringAsFixed(4)} mA)',
      Offset(left, size.height - 18),
      size: 10,
      color: flowing && isForwardBias
          ? const Color(0xFF10B981)
          : Colors.grey.shade600,
      weight: FontWeight.w600,
    );
  }

  @override
  bool shouldRepaint(covariant DiodeCircuitPainter oldDelegate) {
    return oldDelegate.isForwardBias != isForwardBias ||
        oldDelegate.voltageMagnitude != voltageMagnitude ||
        oldDelegate.current != current ||
        oldDelegate.diodeVoltage != diodeVoltage ||
        oldDelegate.flowPhase != flowPhase;
  }
}

// ============================================================
// QUIZ SCREEN
// ============================================================

class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  int currentQuestion = 0;
  int score = 0;
  bool answered = false;
  int? selectedAnswer;

  final List<Map<String, dynamic>> questions = [
    {
      'question': 'What is the typical cut-in voltage for a silicon diode?',
      'options': ['0.3V', '0.5V', '0.7V', '1.0V'],
      'correct': 2,
      'explanation':
          'Silicon diodes have a cut-in voltage of approximately 0.7V.',
    },
    {
      'question': 'In forward bias, the P-side of the diode is connected to:',
      'options': [
        'Negative terminal',
        'Positive terminal',
        'Ground',
        'No connection',
      ],
      'correct': 1,
      'explanation': 'Forward bias requires P-side to positive terminal.',
    },
    {
      'question': 'What happens to the depletion region in reverse bias?',
      'options': ['Narrows', 'Widens', 'Disappears', 'Stays same'],
      'correct': 1,
      'explanation': 'The depletion region widens in reverse bias.',
    },
    {
      'question': 'What is the typical reverse saturation current?',
      'options': ['Amperes', 'Milliamperes', 'Microamperes', 'Kiloamperes'],
      'correct': 2,
      'explanation': 'Reverse saturation current is typically in microamperes.',
    },
  ];

  void _checkAnswer(int index) {
    if (answered) return;
    setState(() {
      answered = true;
      selectedAnswer = index;
      if (index == questions[currentQuestion]['correct']) {
        score++;
      }
    });
  }

  void _nextQuestion() {
    setState(() {
      if (currentQuestion < questions.length - 1) {
        currentQuestion++;
        answered = false;
        selectedAnswer = null;
      } else {
        _showResult();
      }
    });
  }

  void _showResult() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quiz Complete!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Your Score: $score/${questions.length}'),
            const SizedBox(height: 8),
            Text(
              score >= 3
                  ? 'Excellent! You have a good understanding.'
                  : score >= 2
                  ? 'Good job! Review the theory for better understanding.'
                  : 'Keep learning! Review the theory section.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                currentQuestion = 0;
                score = 0;
                answered = false;
                selectedAnswer = null;
              });
            },
            child: const Text('Restart'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final question = questions[currentQuestion];

    return Scaffold(
      appBar: AppBar(title: const Text('Knowledge Quiz')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Question ${currentQuestion + 1}/${questions.length}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF6366F1),
                  ),
                ),
                const Spacer(),
                Text(
                  'Score: $score',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF10B981),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (currentQuestion + 1) / questions.length,
              backgroundColor: Colors.grey.shade200,
              color: const Color(0xFF6366F1),
            ),

            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Text(
                question['question'],
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
            ),

            const SizedBox(height: 20),

            ...List.generate(4, (index) {
              final isSelected = selectedAnswer == index;
              final isCorrect = index == question['correct'];
              final showCorrect = answered && isCorrect;
              final showWrong = answered && isSelected && !isCorrect;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                child: InkWell(
                  onTap: () => _checkAnswer(index),
                  borderRadius: BorderRadius.circular(15),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: showCorrect
                          ? Colors.green.withValues(alpha: 0.1)
                          : showWrong
                          ? Colors.red.withValues(alpha: 0.1)
                          : isSelected
                          ? const Color(0xFF6366F1).withValues(alpha: 0.1)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: showCorrect
                            ? Colors.green
                            : showWrong
                            ? Colors.red
                            : isSelected
                            ? const Color(0xFF6366F1)
                            : const Color(0xFFE2E8F0),
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          showCorrect
                              ? Icons.check_circle
                              : showWrong
                              ? Icons.cancel
                              : isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: showCorrect
                              ? Colors.green
                              : showWrong
                              ? Colors.red
                              : isSelected
                              ? const Color(0xFF6366F1)
                              : Colors.grey,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            question['options'][index],
                            style: const TextStyle(
                              fontSize: 16,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),

            if (answered) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F9FF),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info, color: Color(0xFF3B82F6)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        question['explanation'],
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _nextQuestion,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  child: Text(
                    currentQuestion < questions.length - 1
                        ? 'Next Question'
                        : 'Finish Quiz',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// THEORY SCREEN
// ============================================================

class TheoryScreen extends StatelessWidget {
  const TheoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diode Theory'),
        backgroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PN Junction Diode',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF17202A),
              ),
            ),

            const SizedBox(height: 8),

            Text(
              'Learn how a diode behaves under forward and reverse bias.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),

            const SizedBox(height: 24),

            _theoryCard(
              icon: Icons.memory,
              title: 'What is a Diode?',
              text:
                  'A diode is a semiconductor device that primarily allows '
                  'electric current to flow in one direction. A PN junction '
                  'is formed by joining P-type and N-type semiconductor materials.',
              color: const Color(0xFF6366F1),
            ),

            _theoryCard(
              icon: Icons.arrow_forward,
              title: 'Forward Bias',
              text:
                  'In forward bias, the P-side is connected to the positive '
                  'terminal and the N-side to the negative terminal. The '
                  'depletion region becomes narrower and current increases '
                  'rapidly after the cut-in voltage.',
              color: const Color(0xFF00897B),
            ),

            _theoryCard(
              icon: Icons.arrow_back,
              title: 'Reverse Bias',
              text:
                  'In reverse bias, the P-side is connected to the negative '
                  'terminal and the N-side to the positive terminal. The '
                  'depletion region widens and only a very small leakage '
                  'current flows.',
              color: const Color(0xFF7B1FA2),
            ),

            _theoryCard(
              icon: Icons.bolt,
              title: 'Cut-in Voltage',
              text:
                  'For a typical silicon diode, the cut-in voltage is '
                  'approximately 0.7 V. For a germanium diode, it is '
                  'approximately 0.3 V.',
              color: const Color(0xFFF59E0B),
            ),

            _theoryCard(
              icon: Icons.show_chart,
              title: 'V-I Characteristics',
              text:
                  'The V-I characteristic curve shows the relationship '
                  'between voltage applied across the diode and the current '
                  'flowing through it. In forward bias the current rises '
                  'sharply after the knee voltage, while reverse current '
                  'remains very small until breakdown.',
              color: const Color(0xFF1565C0),
            ),

            const SizedBox(height: 8),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Key Points',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF17202A),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text('• Forward bias → significant current flow'),
                  SizedBox(height: 6),
                  Text('• Reverse bias → very small leakage current'),
                  SizedBox(height: 6),
                  Text('• Silicon cut-in voltage → approximately 0.7 V'),
                  SizedBox(height: 6),
                  Text('• Diode → primarily a unidirectional device'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _theoryCard({
    required IconData icon,
    required String title,
    required String text,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF17202A),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// GRAPH SCREEN
// ============================================================

enum _GraphMode { forward, reverse, both }

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  _GraphMode mode = _GraphMode.forward;
  final experimentData = ExperimentData();

  bool _isLoadingFromDatabase = true;
  String? _databaseError;

  @override
  void initState() {
    super.initState();
    _loadDatabaseReadings();
  }

  Future<void> _loadDatabaseReadings() async {
    try {
      final rows = await ExperimentRepository.fetchReadings();

      final forward = <Reading>[];
      final reverse = <Reading>[];

      for (final row in rows) {
        final type = row['experiment_type'] as String;
        final voltage = (row['vout'] as num).toDouble();
        final current = (row['current_ma'] as num).toDouble();
        final vin = (row['vin'] as num?)?.toDouble() ?? 0;

        final reading = Reading(
          voltage,
          current,
          id: row['id'].toString(),
          vin: vin,
        );

        if (type == 'forward') {
          forward.add(reading);
        } else if (type == 'reverse') {
          reverse.add(reading);
        }
      }

      if (!mounted) return;

      setState(() {
        // Replace in-memory lists with the database results.
        experimentData.forwardReadings
          ..clear()
          ..addAll(forward);

        experimentData.reverseReadings
          ..clear()
          ..addAll(reverse);

        _isLoadingFromDatabase = false;
        _databaseError = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoadingFromDatabase = false;
        _databaseError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingFromDatabase) {
      return Scaffold(
        appBar: AppBar(title: const Text('V-I Graph')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading readings from PostgreSQL...'),
            ],
          ),
        ),
      );
    }

    if (_databaseError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('V-I Graph')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Could not load readings from PostgreSQL.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _databaseError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _isLoadingFromDatabase = true;
                    });
                    _loadDatabaseReadings();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final forward = experimentData.forwardReadings;
    final reverse = experimentData.reverseReadings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('V-I Graph'),
        backgroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _modeTab(
                      'Forward Bias',
                      _GraphMode.forward,
                      const Color(0xFF10B981),
                    ),
                  ),
                  Expanded(
                    child: _modeTab(
                      'Reverse Bias',
                      _GraphMode.reverse,
                      const Color(0xFF8B5CF6),
                    ),
                  ),
                  Expanded(
                    child: _modeTab(
                      'Show Both',
                      _GraphMode.both,
                      const Color(0xFF6366F1),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (mode == _GraphMode.forward) _buildForwardGraph(forward),
            if (mode == _GraphMode.reverse) _buildReverseGraph(reverse),
            if (mode == _GraphMode.both) _buildBothGraph(forward, reverse),
          ],
        ),
      ),
    );
  }

  Widget _modeTab(String label, _GraphMode value, Color color) {
    final selected = mode == value;
    return GestureDetector(
      onTap: () => setState(() => mode = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            color: selected ? color : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _emptyHint(String text) {
    return SizedBox(
      height: 220,
      child: Center(
        child: Text(
          text,
          style: TextStyle(color: Colors.grey.shade600),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildForwardGraph(List<Reading> readings) {
    if (readings.length < 2) {
      return _sectionCard(
        title: 'Forward Characteristics',
        color: const Color(0xFF10B981),
        icon: Icons.arrow_forward,
        child: _emptyHint(
          'Record at least 2 forward-bias readings in the Experiment screen to plot this graph.',
        ),
      );
    }
    final sorted = [...readings]
      ..sort((a, b) => a.voltage.compareTo(b.voltage));
    final spots = sorted.map((r) => FlSpot(r.voltage, r.current)).toList();
    final maxY = sorted.map((r) => r.current).reduce(math.max);

    return _sectionCard(
      title: 'Forward Characteristics',
      color: const Color(0xFF10B981),
      icon: Icons.arrow_forward,
      child: SizedBox(
        height: 260,
        child: LineChart(
          LineChartData(
            gridData: const FlGridData(show: true),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Voltage (V)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 26),
              ),
              leftTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Current (mA)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 40),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: Colors.grey.shade300),
            ),
            minY: 0,
            maxY: maxY * 1.15 + 0.1,
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                color: const Color(0xFF10B981),
                barWidth: 3,
                dotData: const FlDotData(show: true),
                belowBarData: BarAreaData(
                  show: true,
                  color: const Color(0xFF10B981).withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReverseGraph(List<Reading> readings) {
    if (readings.length < 2) {
      return _sectionCard(
        title: 'Reverse Characteristics',
        color: const Color(0xFF8B5CF6),
        icon: Icons.arrow_back,
        child: _emptyHint(
          'Record at least 2 reverse-bias readings in the Experiment screen to plot this graph.',
        ),
      );
    }
    final sorted = [...readings]
      ..sort((a, b) => a.voltage.compareTo(b.voltage));
    final spots = sorted.map((r) => FlSpot(r.voltage, r.current)).toList();
    final minY = sorted.map((r) => r.current).reduce(math.min);

    return _sectionCard(
      title: 'Reverse Characteristics',
      color: const Color(0xFF8B5CF6),
      icon: Icons.arrow_back,
      child: SizedBox(
        height: 260,
        child: LineChart(
          LineChartData(
            gridData: const FlGridData(show: true),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Voltage (V)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 26),
              ),
              leftTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Current (mA)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 46),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: Colors.grey.shade300),
            ),
            maxY: 0.001,
            minY: minY * 1.15 - 0.001,
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                color: const Color(0xFF8B5CF6),
                barWidth: 3,
                dotData: const FlDotData(show: true),
                belowBarData: BarAreaData(
                  show: true,
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBothGraph(List<Reading> forward, List<Reading> reverse) {
    if (forward.length + reverse.length < 2) {
      return _sectionCard(
        title: 'Combined Characteristics',
        color: const Color(0xFF6366F1),
        icon: Icons.show_chart,
        child: _emptyHint(
          'Record readings in both modes to see the combined characteristic curve.',
        ),
      );
    }
    final fwdSorted = [...forward]
      ..sort((a, b) => a.voltage.compareTo(b.voltage));
    final revSorted = [...reverse]
      ..sort((a, b) => a.voltage.compareTo(b.voltage));
    final maxY = fwdSorted.isEmpty
        ? 1.0
        : fwdSorted.map((r) => r.current).reduce(math.max) * 1.15;
    final minY = revSorted.isEmpty
        ? -0.01
        : revSorted.map((r) => r.current).reduce(math.min) * 1.15;
    final minX = revSorted.isEmpty ? 0.0 : revSorted.first.voltage * 1.1;
    final maxX = fwdSorted.isEmpty ? 1.0 : fwdSorted.last.voltage * 1.1 + 0.1;

    return _sectionCard(
      title: 'Combined Characteristics',
      color: const Color(0xFF6366F1),
      icon: Icons.show_chart,
      child: SizedBox(
        height: 280,
        child: LineChart(
          LineChartData(
            gridData: const FlGridData(show: true),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Voltage (V)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 26),
              ),
              leftTitles: AxisTitles(
                axisNameWidget: const Text(
                  'Current (mA)',
                  style: TextStyle(fontSize: 11),
                ),
                sideTitles: SideTitles(showTitles: true, reservedSize: 46),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: Colors.grey.shade300),
            ),
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY == 0 ? 1 : maxY,
            lineBarsData: [
              if (fwdSorted.isNotEmpty)
                LineChartBarData(
                  spots: fwdSorted
                      .map((r) => FlSpot(r.voltage, r.current))
                      .toList(),
                  isCurved: true,
                  color: const Color(0xFF10B981),
                  barWidth: 3,
                  dotData: const FlDotData(show: false),
                ),
              if (revSorted.isNotEmpty)
                LineChartBarData(
                  spots: revSorted
                      .map((r) => FlSpot(r.voltage, r.current))
                      .toList(),
                  isCurved: true,
                  color: const Color(0xFF8B5CF6),
                  barWidth: 3,
                  dotData: const FlDotData(show: false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ANALYSIS SCREEN
// ============================================================

class AnalysisScreen extends StatelessWidget {
  const AnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final data = ExperimentData();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analysis'),
        backgroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Experiment Analysis',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF17202A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Automatic, per-bias analysis of your experimental data',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
            const SizedBox(height: 20),

            // ---------- Forward analysis ----------
            _analysisBlock(
              title: 'Forward Analysis',
              color: const Color(0xFF10B981),
              icon: Icons.arrow_forward,
              stats: data.forwardReadings.isEmpty
                  ? [const _Stat('READINGS', '0')]
                  : [
                      _Stat('READINGS', '${data.forwardReadings.length}'),
                      _Stat(
                        'CUT-IN VOLTAGE',
                        '${data.estimatedCutInVoltage.toStringAsFixed(2)} V',
                      ),
                      _Stat(
                        'MAX CURRENT',
                        '${data.maxForwardCurrent.toStringAsFixed(2)} mA',
                      ),
                      _Stat('FORWARD REGION', data.forwardRegionAssessment),
                    ],
              observation: data.forwardObservationText(),
            ),

            const SizedBox(height: 16),

            // ---------- Reverse analysis ----------
            _analysisBlock(
              title: 'Reverse Analysis',
              color: const Color(0xFF8B5CF6),
              icon: Icons.arrow_back,
              stats: data.reverseReadings.isEmpty
                  ? [const _Stat('READINGS', '0')]
                  : [
                      _Stat('READINGS', '${data.reverseReadings.length}'),
                      _Stat(
                        'REVERSE CURRENT',
                        '${data.maxReverseCurrentMag.toStringAsFixed(4)} mA',
                      ),
                      const _Stat('BREAKDOWN', 'Not reached'),
                    ],
              observation: data.reverseObservationText(),
            ),

            const SizedBox(height: 16),

            // ---------- Conclusion ----------
            _buildSection(
              icon: Icons.assignment,
              title: 'Laboratory Conclusion',
              content: data.getAnalysisConclusion(),
              color: const Color(0xFF1565C0),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const GraphScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.show_chart),
                    label: const Text('View Graph'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ExperimentScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.science),
                    label: const Text('Experiment'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _analysisBlock({
    required String title,
    required Color color,
    required IconData icon,
    required List<_Stat> stats,
    required String observation,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: stats
                .map(
                  (s) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.label,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.value,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
          Text(
            observation,
            style: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Color(0xFF263238),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String title,
    required String content,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF17202A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Color(0xFF263238),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat {
  final String label;
  final String value;
  const _Stat(this.label, this.value);
}
