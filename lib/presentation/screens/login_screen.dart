import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:automato/data/firebase/firebase_repositories.dart';

// ─────────────────────────────────────────────────────────────
// LOGIN SCREEN — FLOATING MINIMALIST MODERN EDITION
// FIXED: Removed initUserGreenhouse() calls. All post-login
//        initialization is now handled by onLoginSuccess in
//        main.dart to prevent double-initialization.
// ─────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;
  final VoidCallback? onNavigateToRegister;
  final FirebaseAuthRepository authRepository;

  const LoginScreen({
    super.key,
    this.onLoginSuccess,
    this.onNavigateToRegister,
    required this.authRepository,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {

  // ── Palette ────────────────────────────────────────────────
  static const _bg       = Color(0xFFF2F5F0);
  static const _green    = Color(0xFF3D6B48);
  static const _greenBtn = Color(0xFF4A7A57);
  static const _textDark = Color(0xFF1E2B1E);
  static const _textMid  = Color(0xFF5A6E5A);
  static const _errorRed = Color(0xFFD94F3D);

  // ── Form state ─────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  bool _isSignUp = false;
  bool _obscure = true;
  bool _loading = false;
  bool _googleLoading = false;  
  String? _errorMsg;

  // ── Fade-in animation ──────────────────────────────────────
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  late final Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic));
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      case 'network-request-failed':
        return 'No internet connection.';
      case 'email-already-in-use':
        return 'An account already exists for this email.';
      case 'weak-password':
        return 'Password is too weak. Enter at least 6 characters.';
      default:
        return 'Authentication failed ($code).';
    }
  }

  // ═══════════════════════════════════════════════════════════
  // FIXED: Removed GreenhouseService.initUserGreenhouse() call.
  // All post-login initialization is now centralized in
  // onLoginSuccess (in main.dart) to prevent double-calling.
  // ═══════════════════════════════════════════════════════════
  Future<void> _handleAuthAction() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _errorMsg = null; });

    try {
      if (_isSignUp) {
        await widget.authRepository.signUp(
          _emailCtrl.text.trim(),
          _passCtrl.text,
        );
      } else {
        await widget.authRepository.signIn(
          _emailCtrl.text.trim(),
          _passCtrl.text,
        );
      }
      // REMOVED: await GreenhouseService.initUserGreenhouse();
      // Post-login init is now handled by onLoginSuccess in main.dart
      if (mounted) widget.onLoginSuccess?.call();
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMsg = _friendlyError(e.code));
    } catch (e) {
      if (mounted) {
        setState(() => _errorMsg = 'Authentication failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // FIXED: Removed GreenhouseService.initUserGreenhouse() call.
  // ═══════════════════════════════════════════════════════════
  Future<void> _handleGoogleSignIn() async {
    setState(() { 
      _googleLoading = true; 
      _errorMsg = null; 
    });
    try {
      final success = await widget.authRepository.signInWithGoogle();
      if (success) {
        // REMOVED: await GreenhouseService.initUserGreenhouse();
        if (mounted) {
          setState(() => _googleLoading = false);
          widget.onLoginSuccess?.call();
        }
      } else {
        if (mounted) setState(() => _googleLoading = false);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _googleLoading = false;
          _errorMsg = _friendlyError(e.code);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _googleLoading = false;
          _errorMsg = 'Google sign-in failed: ${e.toString()}';
        });
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 10),
                      _buildLogoMark(),
                      const SizedBox(height: 24),
                      _buildHeading(),
                      const SizedBox(height: 36),

                      _PillField(
                        controller: _emailCtrl,
                        hint: 'E-mail',
                        icon: Icons.mail_outline_rounded,
                        keyboardType: TextInputType.emailAddress,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Email is required';
                          if (!v.contains('@')) return 'Enter a valid email';
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      _PillField(
                        controller: _passCtrl,
                        hint: 'Password',
                        icon: Icons.lock_outline_rounded,
                        obscure: _obscure,
                        suffix: GestureDetector(
                          onTap: () => setState(() => _obscure = !_obscure),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 18),
                            child: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: _textMid,
                              size: 20,
                            ),
                          ),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Password is required';
                          if (v.length < 6) return 'At least 6 characters';
                          return null;
                        },
                      ),
                      if (_isSignUp) ...[
                        const SizedBox(height: 14),
                        _PillField(
                          controller: _confirmPassCtrl,
                          hint: 'Confirm Password',
                          icon: Icons.lock_outline_rounded,
                          obscure: _obscure,
                          validator: (v) {
                            if (v != _passCtrl.text) {
                              return 'Passwords do not match';
                            }
                            return null;
                          },
                        ),
                      ],

                      if (!_isSignUp) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () {},
                            style: TextButton.styleFrom(
                              foregroundColor: _green,
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Forgot password?',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                      ],

                      if (_errorMsg != null) ...[
                        const SizedBox(height: 12),
                        _ErrorBanner(message: _errorMsg!),
                      ],
                      const SizedBox(height: 28),

                      _SignInButton(
                        loading: _loading,
                        onTap: _handleAuthAction,
                        color: _greenBtn,
                        isSignUp: _isSignUp,
                      ),
                      const SizedBox(height: 24),

                      _buildOrDivider(),
                      const SizedBox(height: 20),

                      _GoogleSignInButton(
                        loading: _googleLoading,
                        onTap: _handleGoogleSignIn,
                      ),
                      const SizedBox(height: 20),

                      _buildRegisterLink(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Sub-builders ───────────────────────────────────────────

  Widget _buildLogoMark() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _green.withOpacity(0.12),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/icon/AUTM-Logo.png',
          fit: BoxFit.cover,
          width: 80,
          height: 80,
          errorBuilder: (context, error, stackTrace) {
            return const Icon(Icons.eco_rounded, color: _green, size: 36);
          },
        ),
      ),
    );
  }

  Widget _buildHeading() {
    return Column(
      children: [
        Text(
          _isSignUp ? 'Create an Account!' : "Let's Get you Ready!",
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily:  'Georgia',
            fontSize:    24,
            fontWeight:  FontWeight.w700,
            color:       _textDark,
            height:      1.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _isSignUp ? 'Register greenhouse credentials' :'Sign in to your greenhouse',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Georgia',
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: _textMid,
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Widget _buildOrDivider() {
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: _textMid.withOpacity(0.2))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text('or',
              style: TextStyle(fontSize: 13, color: _textMid.withOpacity(0.7))),
        ),
        Expanded(child: Container(height: 1, color: _textMid.withOpacity(0.2))),
      ],
    );
  }

  Widget _buildRegisterLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _isSignUp ? "Already have an account? " : "Don't have an account? ",
          style: const TextStyle(fontSize: 13.5, color: _textMid),
        ),
        GestureDetector(
          onTap: () {
            setState(() {
              _isSignUp = !_isSignUp;
              _errorMsg = null;
            });
          },
          child: Text(
            _isSignUp ? 'Sign in' : 'Sign up',
            style: const TextStyle(
              fontSize: 13.5,
              color: _textDark,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: _textDark,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Google Sign In Button ────────────────────────────────────
class _GoogleSignInButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;

  const _GoogleSignInButton({
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          disabledBackgroundColor: Colors.white.withOpacity(0.7),
          foregroundColor: _PillField._textDark,
          elevation: 0,
          side: const BorderSide(color: Color(0xFFDADCE0), width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(50),
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: loading
              ? const SizedBox(
                  key: ValueKey('google_loader'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Color(0xFF4285F4),
                  ),
                )
              : Row(
                  key: const ValueKey('google_label'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/icon/Google-Logo.png',
                      width: 25,
                      height: 25,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.g_mobiledata_rounded, size: 28),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Sign in with Google',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF3C4043),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ── PILL TEXT FIELD ──────────────────────────────────────────
class _PillField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final String? Function(String?)? validator;

  static const _fieldBg = Color(0xFFDFE8DC);
  static const _textDark = Color(0xFF1E2B1E);
  static const _textHint = Color(0xFF8FA68E);
  static const _textMid = Color(0xFF5A6E5A);
  static const _green = Color(0xFF3D6B48);
  static const _errorRed = Color(0xFFD94F3D);

  const _PillField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      style: const TextStyle(
          color: _textDark, fontSize: 15, fontWeight: FontWeight.w400),
      validator: validator,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _textHint, fontSize: 15),
        filled: true,
        fillColor: _fieldBg,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 20, right: 12),
          child: Icon(icon, color: _textMid, size: 20),
        ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 52, minHeight: 52),
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(50),
          borderSide: const BorderSide(color: _green, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(50),
          borderSide: const BorderSide(color: _errorRed, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(50),
          borderSide: const BorderSide(color: _errorRed, width: 1.5),
        ),
        errorStyle: const TextStyle(color: _errorRed, fontSize: 11.5),
      ),
    );
  }
}

// ── Authentication Button ────────────────────────────────────
class _SignInButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  final Color color;
  final bool isSignUp;

  const _SignInButton({
    required this.loading,
    required this.onTap,
    required this.color,
    required this.isSignUp,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withOpacity(0.6),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(50)),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: loading
              ? const SizedBox(
                  key: ValueKey('loader'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white))
              : Text(
                  key: ValueKey(isSignUp ? 'signup_label' : 'signin_label'),
                  isSignUp ? 'Create Account' :'Sign in',
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3)),
        ),
      ),
    );
  }
}

// ── Error banner ─────────────────────────────────────────────
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFD94F3D).withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD94F3D).withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Color(0xFFD94F3D), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFFD94F3D))),
          ),
        ],
      ),
    );
  }
}