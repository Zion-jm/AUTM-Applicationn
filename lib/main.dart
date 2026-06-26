//main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'data/mock/mock_repositories.dart';
import 'data/firebase/firebase_repositories.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/providers/app_state.dart';
import 'services/notification_service.dart';
import 'domain/models/sensor_data.dart';

// ADD THESE IMPORTS for GreenhouseService and GreenhouseSetupWizard
import 'services/greenhouse_service.dart';
import 'presentation/screens/greenhouse_setup_wizard.dart';

import 'presentation/screens/splash_screen.dart' as splash;
import 'presentation/screens/login_screen.dart' as login;
import 'presentation/screens/home_screen.dart';        
import 'presentation/screens/dashboard_screen.dart';
import 'presentation/screens/camera_screen.dart';
import 'presentation/screens/control_screen.dart';
import 'presentation/screens/analytics_screen.dart';
import 'presentation/screens/alerts_screen.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

// Shared auth repo instance
final _authRepo = FirebaseAuthRepository();

// ═══════════════════════════════════════════════════════════
// SHARED LOGIN ROUTING HELPER
// Centralized post-login flow:
//  1. Initialize greenhouse service (resolve existing greenhouse)
//  2. Save FCM token for push notifications
//  3. Check if user needs wizard (per-user Firebase flag)
//  4. Show wizard OR go to HomeShell
// ═══════════════════════════════════════════════════════════
Future<void> _navigateAfterLogin() async {
  // CRITICAL: Clear any cached state from previous sessions
  GreenhouseService.clearAllUserState();

  try {
    await GreenhouseService.initUserGreenhouse();
    await NotificationService.saveFCMToken();
  } catch (e) {
    debugPrint('Post-login init error: $e');
  }

  final needsWizard = await GreenhouseService.checkNeedsWizard();

  if (needsWizard) {
    _navigatorKey.currentState?.pushReplacement(
      _AppEntry._fade(
        GreenhouseSetupWizard(
          onComplete: () async {
            await GreenhouseService.markWizardComplete();
            _navigatorKey.currentState
                ?.pushReplacement(_AppEntry._fade(const HomeShell()));
          },
        ),
      ),
    );
  } else {
    _navigatorKey.currentState
        ?.pushReplacement(_AppEntry._fade(const HomeShell()));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ── Register FCM background handler BEFORE anything else ──
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await Firebase.initializeApp();

  final sensorRepo = FirebaseSensorRepository();
  final deviceRepo = FirebaseDeviceRepository();
  final alertRepo = FirebaseAlertRepository();
  final systemRepo = FirebaseSystemRepository();
  final cameraRepo = MockCameraRepository();

  await NotificationService.init();

  final token = await FirebaseMessaging.instance.getToken();
  debugPrint('════════════════════════════════════════');
  debugPrint('FCM Token: $token');
  debugPrint('════════════════════════════════════════');

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: AppTheme.bg0,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(
        sensorRepository: sensorRepo,
        deviceRepository: deviceRepo,
        alertRepository: alertRepo,
        systemRepository: systemRepo,
        cameraRepository: cameraRepo,
      ),
      child: const AuTOMATOApp(),
    ),
  );
}

class AuTOMATOApp extends StatelessWidget {
  const AuTOMATOApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'AuTOMATO',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const _AppEntry(),
    );
  }
}

class _AppEntry extends StatelessWidget {
  const _AppEntry();

  static Route _fade(Widget page) => PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      );

  void _onSplashFinished(BuildContext context) async{
    final alreadySignedIn = _authRepo.currentUser != null;

    if (alreadySignedIn) {
      try {
        GreenhouseService.clearAllUserState();
        await GreenhouseService.initUserGreenhouse();
        await NotificationService.saveFCMToken();
      } catch (e) {
        debugPrint('Init error: $e');
      }

      final needsWizard = await GreenhouseService.checkNeedsWizard();

      if (needsWizard) {
        _navigatorKey.currentState?.pushReplacement(
          _fade(
            GreenhouseSetupWizard(
              onComplete: () async {
                await GreenhouseService.markWizardComplete();
                _navigatorKey.currentState
                    ?.pushReplacement(_fade(const HomeShell()));
              },
            ),
          ),
        );
      } else {
        _navigatorKey.currentState?.pushReplacement(_fade(const HomeShell()));
      }
    } else {
      _navigatorKey.currentState?.pushReplacement(
        _fade(
          login.LoginScreen(
            authRepository: _authRepo,
            onLoginSuccess: () => _navigateAfterLogin(),
            onNavigateToRegister: () {},
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return splash.SplashScreen(
      onFinished: () => _onSplashFinished(context),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  Widget _screen(int i) {
    switch (i) {
      case 0: return const HomeScreen();
      case 1: return const DashboardScreen();
      case 2: return const CameraScreen();
      case 3: return const AlertsScreen();
      case 4: return const ControlScreen();
      default: return const HomeScreen();
    }
  }

  Future<void> _logout() async {
    await _authRepo.signOut();
    GreenhouseService.clearAllUserState();

    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => login.LoginScreen(
          authRepository: _authRepo,
          onLoginSuccess: () => _navigateAfterLogin(),
          onNavigateToRegister: () {},
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final alertCount = state.alertCount;

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          'automato',
          style: GoogleFonts.sora(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: AppTheme.olive,
            letterSpacing: -1,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_outlined, color: AppTheme.inkMid),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AnalyticsScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      drawer: Drawer(
        backgroundColor: AppTheme.bg0,
        child: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 32, 0, 24),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppTheme.divider, width: 2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'automato',
                      style: GoogleFonts.sora(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.olive,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Smart Greenhouse',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.inkFaint,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<String>(
                  future: GreenhouseService.getMyJoinCode(),
                  builder: (context, snapshot) {
                    final code = snapshot.data ?? '––––––';
                    return ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.normalSurface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppTheme.olive.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'YOUR PERMANENT CODE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.inkFaint,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Text(
                                    code,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.olive,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () {
                                      Clipboard.setData(
                                          ClipboardData(text: code));
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('Join code copied!'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    },
                                    child: const Icon(
                                      Icons.copy_rounded,
                                      color: AppTheme.olive,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Owner reference linkage. For guests, use Single-use invite codes below.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.inkFaint,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

                        if (GreenhouseService.currentUserRole == 'owner') ...[
                          ListTile(
                            leading: const Icon(Icons.share_outlined,
                                color: AppTheme.inkMid),
                            title: const Text(
                              'Invite Guest (One-Time)',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.ink,
                              ),
                            ),
                            onTap: () => _showInviteDialog(context),
                          ),
                          const Divider(height: 1),
                        ],

                        ListTile(
                          leading: const Icon(Icons.add_home_outlined,
                              color: AppTheme.inkMid),
                          title: const Text(
                            'Join a Greenhouse',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.ink,
                            ),
                          ),
                          onTap: () => _showJoinDialog(context),
                        ),
                        const Divider(height: 1),

                        ListTile(
                          leading: const Icon(Icons.logout,
                              color: AppTheme.statusAlert),
                          title: const Text(
                            'Log out',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.statusAlert,
                            ),
                          ),
                          onTap: _logout,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(index: _index, children: List.generate(5, _screen)),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.divider, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
          type: BottomNavigationBarType.fixed,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedItemColor: AppTheme.olive,
          unselectedItemColor: AppTheme.inkMid,
          backgroundColor: AppTheme.bg0,
          elevation: 0,
          selectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.camera_alt_outlined),
              activeIcon: Icon(Icons.camera_alt),
              label: 'Camera',
            ),
            BottomNavigationBarItem(
              label: 'Alerts',
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_outlined),
                  if (alertCount > 0)
                    Positioned(
                        right: -6, top: -6, child: _Badge(count: alertCount)),
                ],
              ),
              activeIcon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    Icons.notifications,
                    color: alertCount > 0 ? AppTheme.statusAlert : null,
                  ),
                  if (alertCount > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: _Badge(count: alertCount),
                    ),
                ],
              ),
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.tune_outlined),
              activeIcon: Icon(Icons.tune),
              label: 'Control',
            ),
          ],
        ),
      ),
    );
  }

  void _showInviteDialog(BuildContext context) {
    String? generatedCode;
    bool loading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.bg0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderLight),
          ),
          title: const Text(
            'Generate Secure Invite',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: AppTheme.ink,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (generatedCode == null) ...[
                const Text(
                  'Select the access level for this guest invitation code:',
                  style: TextStyle(fontSize: 13, color: AppTheme.inkFaint),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: loading
                            ? null
                            : () async {
                                setDialogState(() => loading = true);
                                final code = await GreenhouseService.generateShareCode('control');
                                setDialogState(() {
                                  generatedCode = code;
                                  loading = false;
                                });
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.olive,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Control & View'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: loading
                            ? null
                            : () async {
                                setDialogState(() => loading = true);
                                final code = await GreenhouseService.generateShareCode('view');
                                setDialogState(() {
                                  generatedCode = code;
                                  loading = false;
                                });
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.inkMid,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('View-Only'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const Text(
                  'SHARE INVITE CODE (OR QR equivalent):',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.inkFaint,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.bg1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.divider),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        generatedCode!,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.olive,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: generatedCode!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Invite code copied!')),
                          );
                        },
                        child: const Icon(Icons.copy_rounded, color: AppTheme.olive, size: 20),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This code can only be used once. It is destroyed and disabled immediately on join.',
                  style: TextStyle(fontSize: 11, color: AppTheme.inkFaint, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Close',
                style: TextStyle(color: AppTheme.inkFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showJoinDialog(BuildContext context) {
    final ctrl = TextEditingController();
    bool loading = false;
    String? error;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.bg0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.borderLight),
          ),
          title: const Text(
            'Join a Greenhouse',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: AppTheme.ink,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the join code from the greenhouse owner.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.inkFaint,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  letterSpacing: 2,
                  color: AppTheme.ink,
                ),
                decoration: InputDecoration(
                  hintText: 'AUTM-0000',
                  hintStyle: const TextStyle(
                      color: AppTheme.inkGhost, letterSpacing: 2),
                  filled: true,
                  fillColor: AppTheme.bg2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                        color: AppTheme.olive, width: 1.5),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: const TextStyle(
                      color: AppTheme.statusAlert, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.inkFaint),
              ),
            ),
            ElevatedButton(
              onPressed: loading
                  ? null
                  : () async {
                      setDialogState(() {
                        loading = true;
                        error = null;
                      });

                      final result =
                          await GreenhouseService.joinGreenhouse(ctrl.text);

                      if (result.success) {
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Connected to ${result.greenhouseName}!'),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      } else {
                        setDialogState(() {
                          loading = false;
                          error = result.errorMessage;
                        });
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.olive,
                foregroundColor: AppTheme.bg0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;
  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      decoration: BoxDecoration(
        color: AppTheme.statusAlert,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.bg0, width: 1.5),
      ),
      child: Center(
        child: Text(
          count > 99 ? '99+' : '$count',
          style: const TextStyle(
            color: AppTheme.bg0,
            fontSize: 9,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}