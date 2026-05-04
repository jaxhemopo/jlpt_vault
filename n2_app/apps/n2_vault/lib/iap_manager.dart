import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IapManager {
  static final IapManager _instance = IapManager._internal();
  factory IapManager() => _instance;
  IapManager._internal();

  static const String _apiKey = String.fromEnvironment(
    'REVENUECAT_PUBLIC_API_KEY',
    defaultValue: '',
  );

  bool _isFullUnlockOwned = false;
  bool get isFullUnlockOwned => _isFullUnlockOwned;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _isFullUnlockOwned = prefs.getBool('is_unlocked') ?? false;

    if (_apiKey.isEmpty) {
      if (kDebugMode) {
        print(
          'IapManager: REVENUECAT_PUBLIC_API_KEY not set (--dart-define=...); skipping RevenueCat.',
        );
      }
      return;
    }

    await Purchases.setLogLevel(LogLevel.debug);

    PurchasesConfiguration configuration = PurchasesConfiguration(_apiKey);
    await Purchases.configure(configuration);

    Purchases.addCustomerInfoUpdateListener((customerInfo) {
      _updateUnlockStatus(customerInfo);
    });

    try {
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      _updateUnlockStatus(customerInfo);
    } catch (e) {
      print("Failed to get customer info: $e");
    }
  }

  void _updateUnlockStatus(CustomerInfo customerInfo) async {
    // Log active entitlements to help debug ID mismatches
    if (customerInfo.entitlements.active.isNotEmpty) {
      print("RC_DEBUG: Active Entitlements: ${customerInfo.entitlements.active.keys.toList()}");
    } else {
      print("RC_DEBUG: No active entitlements found.");
    }

    // Check specific entitlement and any active entitlement as fallback
    final entitlement = customerInfo.entitlements.all["N2 Vault Full Unlock"];
    bool isUnlocked = (entitlement != null && entitlement.isActive) || 
                      customerInfo.entitlements.active.isNotEmpty;
    
    if (_isFullUnlockOwned != isUnlocked) {
      _isFullUnlockOwned = isUnlocked;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_unlocked', isUnlocked);
    }
  }

  Future<bool> hasActiveAccess() async {
    if (_isFullUnlockOwned) return true;
    if (_apiKey.isEmpty) return _isFullUnlockOwned;

    try {
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      _updateUnlockStatus(customerInfo);
      return _isFullUnlockOwned;
    } catch (e) {
      print("Failed to check access with RC: $e");
      return _isFullUnlockOwned;
    }
  }

  Future<void> restorePurchases() async {
    if (_apiKey.isEmpty) return;
    try {
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      _updateUnlockStatus(customerInfo);
    } on PlatformException catch (e) {
      print("Failed to restore purchases: $e");
    }
  }
}
