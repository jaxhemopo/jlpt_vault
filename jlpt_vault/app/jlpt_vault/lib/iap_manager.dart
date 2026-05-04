import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IapManager {
  static final IapManager _instance = IapManager._internal();
  factory IapManager() => _instance;
  IapManager._internal();

  /// Public SDK key from RevenueCat — pass at compile time, never commit:
  /// `flutter run --dart-define=REVENUECAT_PUBLIC_API_KEY=<your_public_sdk_key>`
  static const String _apiKey = String.fromEnvironment(
    'REVENUECAT_PUBLIC_API_KEY',
    defaultValue: '',
  );
  // Dev-safe default: RC is off unless explicitly enabled.
  static const bool _rcEnabled =
      bool.fromEnvironment('ENABLE_REVENUECAT', defaultValue: kReleaseMode);
  bool get isRevenueCatEnabled => _rcEnabled;
  bool _isConfigured = false;

  bool _isFullUnlockOwned = false;
  bool get isFullUnlockOwned => _isFullUnlockOwned;

  /// Call from [main] with prefs already loaded so [hasActiveAccess] is sane
  /// before deferred [initialize] finishes (RevenueCat configure is async).
  void hydrateUnlockFromPrefs(SharedPreferences prefs) {
    _isFullUnlockOwned = prefs.getBool('is_unlocked') ?? false;
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _isFullUnlockOwned = prefs.getBool('is_unlocked') ?? false;
    if (!_rcEnabled) return;
    if (_apiKey.isEmpty) {
      if (kDebugMode) {
        print(
          'RevenueCat: set REVENUECAT_PUBLIC_API_KEY via --dart-define for release; skipping configure.',
        );
      }
      return;
    }

    try {
      await Purchases.setLogLevel(LogLevel.debug);
      final configuration = PurchasesConfiguration(_apiKey);
      await Purchases.configure(configuration);
      _isConfigured = true;
    } catch (e) {
      // Keep app usable even if RC has temporary config/store issues at startup.
      print("RC init failed: $e");
      _isConfigured = false;
    }
  }

  Future<void> _updateUnlockStatus(CustomerInfo customerInfo) async {
    // Log active entitlements to help debug ID mismatches
    if (customerInfo.entitlements.active.isNotEmpty) {
      print("RC_DEBUG: Active Entitlements: ${customerInfo.entitlements.active.keys.toList()}");
    } else {
      print("RC_DEBUG: No active entitlements found.");
    }

    // Prefer unified vault entitlement; fall back to legacy N3 id or any active entitlement.
    final vaultEnt = customerInfo.entitlements.all["JLPT Vault Full Unlock"] ??
        customerInfo.entitlements.all["N3 Vault Full Unlock"];
    bool isUnlocked = (vaultEnt != null && vaultEnt.isActive) ||
        customerInfo.entitlements.active.isNotEmpty;
    
    if (_isFullUnlockOwned != isUnlocked) {
      _isFullUnlockOwned = isUnlocked;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_unlocked', isUnlocked);
    }
  }

  Future<bool> hasActiveAccess() async {
    if (_isFullUnlockOwned) return true;
    if (!_rcEnabled) return _isFullUnlockOwned;
    if (_apiKey.isEmpty) return _isFullUnlockOwned;

    try {
      if (!_isConfigured) {
        final configuration = PurchasesConfiguration(_apiKey);
        await Purchases.configure(configuration);
        _isConfigured = true;
      }
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      await _updateUnlockStatus(customerInfo);
      return _isFullUnlockOwned;
    } catch (e) {
      print("Failed to check access with RC: $e");
      return _isFullUnlockOwned;
    }
  }

  Future<void> restorePurchases() async {
    if (!_rcEnabled) return;
    if (_apiKey.isEmpty) return;
    try {
      if (!_isConfigured) {
        final configuration = PurchasesConfiguration(_apiKey);
        await Purchases.configure(configuration);
        _isConfigured = true;
      }
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      await _updateUnlockStatus(customerInfo);
    } on PlatformException catch (e) {
      print("Failed to restore purchases: $e");
    }
  }
}
