import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:automato/services/greenhouse_service.dart';
import 'package:automato/presentation/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────
// GREENHOUSE SETUP WIZARD
// Shown once to new users after account creation.
// Flow: Welcome → Enter ESP32 Code → Done
//
// Place at: lib/presentation/screens/greenhouse_setup_wizard.dart
// ─────────────────────────────────────────────────────────────

class GreenhouseSetupWizard extends StatefulWidget {
  /// Called when setup is complete (code entered OR skipped).
  final VoidCallback onComplete;

  const GreenhouseSetupWizard({super.key, required this.onComplete});

  @override
  State<GreenhouseSetupWizard> createState() => _GreenhouseSetupWizardState();
}

class _GreenhouseSetupWizardState extends State<GreenhouseSetupWizard>
    with SingleTickerProviderStateMixin {
  // ── Palette — matches login screen & app theme ─────────────
  static const _bg = Color(0xFFF2F5F0);
  static const _green = Color(0xFF3D6B48);
  static const _greenBtn = Color(0xFF4A7A57);
  static const _textDark = Color(0xFF1E2B1E);
  static const _textMid = Color(0xFF5A6E5A);
  static const _textFaint = Color(0xFF8FA68E);
  static const _fieldBg = Color(0xFFDFE8DC);
  static const _errorRed = Color(0xFFD94F3D);
  static const _successGreen = Color(0xFF2E7D52);

  // ── Wizard state ───────────────────────────────────────────
  int _step = 0; // 0 = Welcome, 1 = Enter Code, 2 = Done
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _errorMsg;
  String? _connectedGreenhouseName;

  // ── Page transition animation ──────────────────────────────
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  // ── Transition to next step with animation ─────────────────
  void _goToStep(int step) async {
    await _animCtrl.reverse();
    setState(() {
      _step = step;
      _errorMsg = null;
    });
    _animCtrl.forward();
  }

  // ── Handle ESP32 code submission ───────────────────────────
  Future<void> _connectGreenhouse() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _errorMsg = 'Please enter the code from your device.');
      return;
    }

    setState(() {
      _loading = true;
      _errorMsg = null;
    });

    try {
      // Use joinGreenhouse — it handles both permanent join codes
      // (from ESP32 label) and single-use invite codes.
      final result = await GreenhouseService.joinGreenhouse(code);

      if (result.success) {
        // Mark wizard as complete only on successful connection
        await GreenhouseService.markWizardComplete();

        setState(() {
          _loading = false;
          _connectedGreenhouseName = result.greenhouseName;
        });
        _goToStep(2); // → Done
      } else {
        setState(() {
          _loading = false;
          _errorMsg = result.errorMessage ?? 'Invalid code. Check the label on your device.';
        });
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _errorMsg = 'Connection failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: _buildStep(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildWelcome();
      case 1:
        return _buildEnterCode();
      case 2:
        return _buildDone();
      default:
        return _buildWelcome();
    }
  }

  // ══════════════════════════════════════════════════════════
  // STEP 0 — WELCOME
  // ══════════════════════════════════════════════════════════
  Widget _buildWelcome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 60),

        // Logo
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _green.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/icon/AUTM-Logo.png',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.eco_rounded, color: _green, size: 32),
            ),
          ),
        ),

        const SizedBox(height: 40),

        // Step indicator
        _StepIndicator(current: 0, total: 2),

        const SizedBox(height: 28),

        // Heading
        const Text(
          'Welcome to\nAuTOMATO.',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            color: _textDark,
            height: 1.1,
            letterSpacing: -1,
          ),
        ),

        const SizedBox(height: 16),

        const Text(
          'Your account is ready. Before live data appears on your dashboard, you need to connect your greenhouse device.',
          style: TextStyle(
            fontSize: 15,
            color: _textMid,
            height: 1.55,
            fontWeight: FontWeight.w400,
          ),
        ),

        const SizedBox(height: 40),

        // What you'll need card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _green.withOpacity(0.07),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _green.withOpacity(0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WHAT YOU\'LL NEED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: _green,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              _NeedItem(
                icon: Icons.developer_board_rounded,
                label: 'Your ESP32 greenhouse device',
              ),
              const SizedBox(height: 10),
              _NeedItem(
                icon: Icons.label_outline_rounded,
                label: 'The code printed on your device label\n(looks like: AUTM-2847)',
              ),
            ],
          ),
        ),

        const Spacer(),

        // CTA
        _WizardButton(
          label: 'Connect My Greenhouse',
          onTap: () => _goToStep(1),
        ),

        const SizedBox(height: 14),

        // Skip link
        Center(
          child: TextButton(
            onPressed: () async {
              await GreenhouseService.markWizardComplete();
              widget.onComplete();
            },
            style: TextButton.styleFrom(
              foregroundColor: _textFaint,
              padding: EdgeInsets.zero,
            ),
            child: const Text(
              'Skip for now — I\'ll connect later',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
                decorationColor: _textFaint,
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════
  // STEP 1 — ENTER CODE
  // ══════════════════════════════════════════════════════════
  Widget _buildEnterCode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 60),

        // Back button
        GestureDetector(
          onTap: () => _goToStep(0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.arrow_back_rounded, color: _textMid, size: 18),
              const SizedBox(width: 6),
              const Text(
                'Back',
                style: TextStyle(
                  fontSize: 14,
                  color: _textMid,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        _StepIndicator(current: 1, total: 2),

        const SizedBox(height: 28),

        const Text(
          'Enter your\ndevice code.',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            color: _textDark,
            height: 1.1,
            letterSpacing: -1,
          ),
        ),

        const SizedBox(height: 12),

        const Text(
          'Find the sticker or label on your ESP32 greenhouse device and enter the code below.',
          style: TextStyle(
            fontSize: 15,
            color: _textMid,
            height: 1.55,
          ),
        ),

        const SizedBox(height: 36),

        // Code input
        TextField(
          controller: _codeCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 28,
            letterSpacing: 4,
            color: _textDark,
          ),
          decoration: InputDecoration(
            hintText: 'AUTM-0000',
            hintStyle: const TextStyle(
              color: _textFaint,
              fontSize: 28,
              letterSpacing: 4,
              fontWeight: FontWeight.w900,
            ),
            filled: true,
            fillColor: _fieldBg,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 22,
              horizontal: 20,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: _green, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: _errorRed, width: 1.5),
            ),
          ),
          onChanged: (_) {
            if (_errorMsg != null) setState(() => _errorMsg = null);
          },
          onSubmitted: (_) => _connectGreenhouse(),
        ),

        // Error message
        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _errorMsg!),
        ],

        const SizedBox(height: 14),

        // Helper text
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline_rounded, size: 13, color: _textFaint),
              const SizedBox(width: 6),
              const Text(
                'The code is on the label of your device',
                style: TextStyle(
                  fontSize: 12,
                  color: _textFaint,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),

        const Spacer(),

        _WizardButton(
          label: 'Connect',
          loading: _loading,
          onTap: _connectGreenhouse,
        ),

        const SizedBox(height: 14),

        Center(
          child: TextButton(
            onPressed: widget.onComplete,
            style: TextButton.styleFrom(
              foregroundColor: _textFaint,
              padding: EdgeInsets.zero,
            ),
            child: const Text(
              'Skip — connect later from settings',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
                decorationColor: _textFaint,
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════
  // STEP 2 — DONE
  // ══════════════════════════════════════════════════════════
  Widget _buildDone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(),

        // Success icon
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: _successGreen.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_circle_rounded,
            color: _successGreen,
            size: 48,
          ),
        ),

        const SizedBox(height: 28),

        Text(
          _connectedGreenhouseName != null
              ? 'Connected to\n$_connectedGreenhouseName!'
              : 'Greenhouse\nConnected!',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w900,
            color: _textDark,
            height: 1.15,
            letterSpacing: -0.8,
          ),
        ),

        const SizedBox(height: 16),

        const Text(
          'Your dashboard will now show live sensor data from your greenhouse device.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            color: _textMid,
            height: 1.55,
          ),
        ),

        const SizedBox(height: 32),

        // What to expect
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _successGreen.withOpacity(0.07),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _successGreen.withOpacity(0.2)),
          ),
          child: Column(
            children: [
              _DoneItem(
                icon: Icons.sensors_rounded,
                text: 'Live sensor readings appear on the Dashboard',
              ),
              const SizedBox(height: 12),
              _DoneItem(
                icon: Icons.notifications_outlined,
                text: 'Alerts notify you when conditions go out of range',
              ),
              const SizedBox(height: 12),
              _DoneItem(
                icon: Icons.tune_rounded,
                text: 'Control your devices from the Control tab',
              ),
            ],
          ),
        ),

        const Spacer(),

        _WizardButton(
          label: 'Go to Dashboard',
          onTap: () async {
            await GreenhouseService.markWizardComplete();
            widget.onComplete();
          },
        ),

        const SizedBox(height: 32),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// SUBWIDGETS
// ─────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int current; // 0-indexed
  final int total;

  const _StepIndicator({required this.current, required this.total});

  static const _green = Color(0xFF3D6B48);
  static const _textFaint = Color(0xFF8FA68E);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        final isActive = i <= current;
        final isCurrentStep = i == current;
        return Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: isCurrentStep ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: isActive ? _green : _textFaint.withOpacity(0.3),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            if (i < total - 1) const SizedBox(width: 6),
          ],
        );
      }),
    );
  }
}

class _WizardButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool loading;

  static const _greenBtn = Color(0xFF4A7A57);

  const _WizardButton({
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _greenBtn,
          disabledBackgroundColor: _greenBtn.withOpacity(0.6),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(50),
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: loading
              ? const SizedBox(
                  key: ValueKey('loader'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : Text(
                  key: ValueKey(label),
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
        ),
      ),
    );
  }
}

class _NeedItem extends StatelessWidget {
  final IconData icon;
  final String label;

  static const _green = Color(0xFF3D6B48);
  static const _textMid = Color(0xFF5A6E5A);

  const _NeedItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _green, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: _textMid,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _DoneItem extends StatelessWidget {
  final IconData icon;
  final String text;

  static const _successGreen = Color(0xFF2E7D52);
  static const _textMid = Color(0xFF5A6E5A);

  const _DoneItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _successGreen, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: _textMid,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  static const _errorRed = Color(0xFFD94F3D);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _errorRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _errorRed.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: _errorRed, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: _errorRed),
            ),
          ),
        ],
      ),
    );
  }
}