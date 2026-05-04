import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

class AppTheme {
  static final lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.light(
      primary: const Color(0xFFe63946),
      surface: Colors.white.withOpacity(0.1),
    ),
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
  );

  static final darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.dark(
      primary: const Color(0xFFee8c2b),
      surface: Colors.black.withOpacity(0.2),
    ),
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
  );
}

class AppColors {
  static Color text(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87;
  static Color subText(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white54 : Colors.black54;
  static Color icon(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87;
  static Color divider(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.black12;
}

class BackgroundManager {
  static final List<String> lightModeImages = [
    'assets/background_light_01.jpeg',
    'assets/background_light_2.jpeg',
    'assets/background_light_3.jpeg',
    'assets/background_light_4.jpeg',
  ];

  static final List<String> darkModeImages = [
    'assets/background_dark_1.jpeg',
    'assets/background_dark_2.jpeg',
    'assets/background_dark_3.jpeg',
    'assets/background_dark_4.jpeg',
  ];

  static String getRandomBackground(bool isDarkMode) {
    final images = isDarkMode ? darkModeImages : lightModeImages;
    return images[Random().nextInt(images.length)];
  }
}

class Glassmorphism {
  static BoxDecoration boxDecoration({
    required BuildContext context,
    double borderRadius = 20,
    double opacity = 0.1,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: (isDark ? Colors.black : Colors.white).withOpacity(opacity),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: (isDark ? Colors.white : Colors.black).withOpacity(0.1),
        width: 1.5,
      ),
    );
  }

  static Widget frostedContainer({
    required BuildContext context,
    required Widget child,
    double blur = 10,
    double borderRadius = 20,
    double opacity = 0.1,
    EdgeInsetsGeometry? padding,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: boxDecoration(
            context: context,
            borderRadius: borderRadius,
            opacity: opacity,
          ),
          child: child,
        ),
      ),
    );
  }
}
