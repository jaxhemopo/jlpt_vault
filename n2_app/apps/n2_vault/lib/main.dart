import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme_manager.dart';
import 'home_screen.dart';
import 'iap_manager.dart';
import 'notification_manager.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load saved theme
  final prefs = await SharedPreferences.getInstance();
  final savedTheme = prefs.getString('theme_mode') ?? 'system';
  themeNotifier.value = _themeModeFromString(savedTheme);

  // Initialize IAP
  await IapManager().initialize();
  
  // Initialize Notifications
  await NotificationManager().initialize();
  
  runApp(const N2VaultApp());
}

ThemeMode _themeModeFromString(String theme) {
  switch (theme) {
    case 'light': return ThemeMode.light;
    case 'dark': return ThemeMode.dark;
    default: return ThemeMode.system;
  }
}

class N2VaultApp extends StatelessWidget {
  const N2VaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, __) {
        return MaterialApp(
          title: 'N2 Vault',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          home: const MainScaffold(
            child: HomeScreen(),
          ),
        );
      },
    );
  }
}

class MainScaffold extends StatefulWidget {
  final Widget child;
  const MainScaffold({super.key, required this.child});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  String? _bgImage;
  bool? _lastIsDark;

  @override
  void initState() {
    super.initState();
    _checkInitialAccess();
  }

  Future<void> _checkInitialAccess() async {
    // Startup Trigger: On app launch, immediately trigger the RevenueCat Paywall if no access
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final hasAccess = await IapManager().hasActiveAccess();
      if (!hasAccess && mounted) {
        _showStartupPaywall();
      }
    });
  }

  Future<void> _showStartupPaywall() async {
    try {
      Offerings offerings = await Purchases.getOfferings();
      // Using 'Vault Access' as configured by the user previously
      Offering? offering = offerings.all["Vault Access"];
      if (mounted) {
        await RevenueCatUI.presentPaywall(offering: offering);
      }
    } catch (e) {
      print("STARTUP_PAYWALL_ERROR: $e");
      if (mounted) {
        await RevenueCatUI.presentPaywall();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    if (_bgImage == null || _lastIsDark != isDark) {
      _bgImage = BackgroundManager.getRandomBackground(isDark);
      _lastIsDark = isDark;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Image
          if (_bgImage != null)
            Image.asset(
              _bgImage!,
              fit: BoxFit.cover,
            ),
          // Content
          widget.child,
        ],
      ),
    );
  }
}
