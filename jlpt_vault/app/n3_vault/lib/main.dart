import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme_manager.dart';
import 'home_screen.dart';
import 'level_select_screen.dart';
import 'database_helper.dart';
import 'iap_manager.dart';
import 'notification_manager.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load saved theme (fast, local only)
  final prefs = await SharedPreferences.getInstance();
  final savedTheme = prefs.getString('theme_mode') ?? 'system';
  themeNotifier.value = _themeModeFromString(savedTheme);
  IapManager().hydrateUnlockFromPrefs(prefs);

  runApp(const JlptVaultApp());

  // RevenueCat + local notifications can hit the network / native APIs and stall
  // the first frame if awaited before runApp — run after UI is up.
  unawaited(_initPluginsAfterFirstFrame());
}

Future<void> _initPluginsAfterFirstFrame() async {
  await Future<void>.delayed(Duration.zero);
  try {
    await IapManager().initialize();
  } catch (e, st) {
    debugPrint('IAP_INIT_DEFERRED: $e\n$st');
  }
  try {
    await NotificationManager().initialize();
  } catch (e, st) {
    debugPrint('NOTIFICATIONS_INIT_DEFERRED: $e\n$st');
  }
}

ThemeMode _themeModeFromString(String theme) {
  switch (theme) {
    case 'light': return ThemeMode.light;
    case 'dark': return ThemeMode.dark;
    default: return ThemeMode.system;
  }
}

class JlptVaultApp extends StatelessWidget {
  const JlptVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, __) {
        return MaterialApp(
          title: 'JLPT Vault',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          home: const VaultRoot(),
        );
      },
    );
  }
}

class VaultRoot extends StatefulWidget {
  const VaultRoot({super.key});

  @override
  State<VaultRoot> createState() => _VaultRootState();
}

class _VaultRootState extends State<VaultRoot> {
  bool _ready = false;
  bool _hasLevel = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(DatabaseHelper.selectedJlptLevelKey);
    final parsed = int.tryParse(s ?? '');
    if (parsed != null && parsed >= 1 && parsed <= 5) {
      try {
        await DatabaseHelper().openForLevel(parsed);
        if (mounted) {
          setState(() {
            _hasLevel = true;
            _ready = true;
          });
        }
        return;
      } catch (e) {
        print('VAULT_ROOT: failed to open level $parsed: $e');
      }
    }
    if (mounted) {
      setState(() {
        _hasLevel = false;
        _ready = true;
      });
    }
  }

  void _showLevelPicker() {
    if (mounted) {
      setState(() => _hasLevel = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_hasLevel) {
      return LevelSelectScreen(
        onLevelChosen: () {
          if (mounted) setState(() => _hasLevel = true);
        },
      );
    }
    return MainScaffold(
      child: HomeScreen(
        onBackToLevels: _showLevelPicker,
      ),
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
