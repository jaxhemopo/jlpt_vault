import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'theme_manager.dart';
import 'level_select_screen.dart';
import 'main.dart'; // Access themeNotifier
import 'iap_manager.dart';
import 'notification_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _dailyNewCards = 20;
  int _dailyReviews = 100;
  
  int _vocabTotal = 0;
  int _grammarTotal = 0;
  bool _isLoading = true;
  String _currentTheme = 'system';
  bool _isUnlocked = false;
  bool _notificationsEnabled = false;
  int _reminderHour = 9;
  int _reminderMinute = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final vocabStats = await DatabaseHelper().getSRSStats(true);
    final grammarStats = await DatabaseHelper().getSRSStats(false);
    final prefs = await SharedPreferences.getInstance();
    
    // Check real-time access from RevenueCat
    final hasAccess = await IapManager().hasActiveAccess();
    
    if (mounted) {
      setState(() {
        _vocabTotal = vocabStats['total'] as int? ?? 0;
        _grammarTotal = grammarStats['total'] as int? ?? 0;
        _dailyNewCards = prefs.getInt('daily_new_card_limit') ?? 20;
        _dailyReviews = prefs.getInt('daily_review_limit') ?? 100;
        _currentTheme = prefs.getString('theme_mode') ?? 'system';
        _isUnlocked = hasAccess;
        _notificationsEnabled = prefs.getBool('notifications_enabled') ?? false;
        _reminderHour = prefs.getInt('reminder_hour') ?? 9;
        _reminderMinute = prefs.getInt('reminder_minute') ?? 0;
        _isLoading = false;
      });
    }
  }

  void _showResetConfirmation() {
    final TextEditingController _resetController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: Colors.redAccent.withOpacity(0.5), width: 1.5),
            ),
            title: Text(
              "Reset All Progress?",
              style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "This will completely erase your study history. The vault will be reset to its default state. This Action cannot be undone, all progress will be lost!!!",
                  style: TextStyle(color: AppColors.subText(context)),
                ),
                const SizedBox(height: 24),
                const Text(
                  "Type 'RESET' to confirm:",
                  style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _resetController,
                  onChanged: (val) {
                    setDialogState(() {}); // rebuild buttons
                  },
                  autofocus: true,
                  style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.bold, letterSpacing: 2),
                  decoration: InputDecoration(
                    hintText: "RESET",
                    hintStyle: TextStyle(color: AppColors.text(context).withOpacity(0.2)),
                    filled: true,
                    fillColor: AppColors.text(context).withOpacity(0.05),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white12)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.redAccent)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("CANCEL", style: TextStyle(color: AppColors.subText(context))),
              ),
              TextButton(
                onPressed: _resetController.text == "RESET" ? () async {
                  await DatabaseHelper().resetProgress();
                  await _loadStats();
                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Study progress has been completely reset.')),
                    );
                  }
                } : null,
                child: Text(
                  "RESET VAULT",
                  style: TextStyle(
                    color: _resetController.text == "RESET" ? Colors.redAccent : Colors.white10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = AppColors.text(context);
    final subColor = AppColors.subText(context);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "SETTINGS",
          style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.bold, fontSize: 16, color: textColor),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader(context, "STUDY OPTIONS"),
              const SizedBox(height: 16),
              _buildSettingsCard(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.layers_outlined, color: Theme.of(context).colorScheme.primary),
                      title: Text("JLPT level", style: TextStyle(color: textColor, fontWeight: FontWeight.w500)),
                      subtitle: Text(
                        DatabaseHelper().selectedLevel != null
                            ? "Currently N${DatabaseHelper().selectedLevel}"
                            : "Not set",
                        style: TextStyle(color: subColor, fontSize: 12),
                      ),
                      trailing: Icon(Icons.chevron_right, color: subColor.withOpacity(0.5)),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (ctx) => LevelSelectScreen(
                              isChangingLevel: true,
                              onLevelChosen: () {
                                if (mounted) _loadStats();
                              },
                            ),
                          ),
                        ).then((_) => _loadStats());
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    _buildDropdownTile(
                      context: context,
                      title: "Daily New Cards",
                      subtitle: "Limit new cards per session",
                      value: _dailyNewCards,
                      options: [10, 20, 30, 50, 75, 100],
                      onChanged: (val) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt('daily_new_card_limit', val!);
                        setState(() => _dailyNewCards = val);
                      },
                      icon: Icons.auto_awesome_motion_outlined,
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    _buildDropdownTile(
                      context: context,
                      title: "Daily Review Limit",
                      subtitle: "Maximum due reviews per day",
                      value: _dailyReviews,
                      options: [50, 100, 150, 200, 500],
                      onChanged: (val) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt('daily_review_limit', val!);
                        setState(() => _dailyReviews = val);
                      },
                      icon: Icons.history_edu_outlined,
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    _buildThemeDropdownTile(
                      context: context,
                      title: "App Theme",
                      subtitle: "Change the appearance of the app",
                      value: _currentTheme,
                      options: ['light', 'dark', 'system'],
                      onChanged: (val) async {
                        if (val == null) return;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('theme_mode', val);
                        
                        ThemeMode mode;
                        if (val == 'light') mode = ThemeMode.light;
                        else if (val == 'dark') mode = ThemeMode.dark;
                        else mode = ThemeMode.system;
                        
                        themeNotifier.value = mode;
                        setState(() => _currentTheme = val);
                      },
                      icon: Icons.palette_outlined,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 48),

              _buildSectionHeader(context, "NOTIFICATIONS"),
              const SizedBox(height: 16),
              _buildSettingsCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _notificationsEnabled,
                      activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: (val) async {
                        final prefs = await SharedPreferences.getInstance();
                        if (val) {
                          bool granted = await NotificationManager().requestPermissions();
                          if (!granted) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Notification permission denied. Please enable in System Settings.')),
                              );
                            }
                            return;
                          }
                        }
                        
                        await prefs.setBool('notifications_enabled', val);
                        setState(() => _notificationsEnabled = val);
                        
                        if (val) {
                          await NotificationManager().scheduleDailyReminder(_reminderHour, _reminderMinute);
                        } else {
                          await NotificationManager().cancelAll();
                        }
                      },
                      secondary: Icon(Icons.notifications_active_outlined, color: Theme.of(context).colorScheme.primary),
                      title: Text("Daily Study Reminder", style: TextStyle(color: textColor, fontWeight: FontWeight.w500)),
                      subtitle: Text("Get reminded when cards are ready", style: TextStyle(color: subColor, fontSize: 12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    ),
                    if (_notificationsEnabled) ...[
                      Divider(color: AppColors.divider(context), height: 1),
                      ListTile(
                        leading: Icon(Icons.access_time, color: subColor),
                        title: Text("Reminder Time", style: TextStyle(color: textColor)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "${_reminderHour.toString().padLeft(2, '0')}:${_reminderMinute.toString().padLeft(2, '0')}",
                              style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.edit, color: subColor.withOpacity(0.5), size: 16),
                          ],
                        ),
                        onTap: () async {
                          final TimeOfDay? picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(hour: _reminderHour, minute: _reminderMinute),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: ColorScheme.dark(
                                    primary: Theme.of(context).colorScheme.primary,
                                    onPrimary: Colors.black,
                                    surface: Colors.grey[900]!,
                                    onSurface: Colors.white,
                                  ),
                                  textButtonTheme: TextButtonThemeData(
                                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.primary),
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );
                          if (picked != null) {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setInt('reminder_hour', picked.hour);
                            await prefs.setInt('reminder_minute', picked.minute);
                            setState(() {
                              _reminderHour = picked.hour;
                              _reminderMinute = picked.minute;
                            });
                            await NotificationManager().scheduleDailyReminder(picked.hour, picked.minute);
                          }
                        },
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 48),

              _buildSectionHeader(context, "MEMBERSHIP"),
              const SizedBox(height: 16),
              _buildSettingsCard(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        _isUnlocked ? Icons.verified_user : Icons.lock_outline,
                        color: _isUnlocked ? Colors.greenAccent : Colors.orangeAccent,
                      ),
                      title: Text(
                        _isUnlocked ? "Premium Access" : "Basic Access",
                        style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        _isUnlocked 
                          ? "Membership Active" 
                          : "Upgrade for full access",
                        style: TextStyle(color: subColor, fontSize: 12),
                      ),
                      trailing: _isUnlocked 
                        ? const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20)
                        : TextButton(
                            onPressed: () async {
                              try {
                                Offerings offerings = await Purchases.getOfferings();
                                Offering? offering = offerings.all["Vault Access"];
                                await RevenueCatUI.presentPaywall(offering: offering);
                              } catch (e) {
                                print("Upgrade Paywall Error: $e");
                                await RevenueCatUI.presentPaywall();
                              }
                              _loadStats();
                            },
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.orangeAccent.withOpacity(0.1),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text("UPGRADE", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    if (_isUnlocked) ...[
                      ListTile(
                        leading: Icon(Icons.manage_accounts, color: subColor),
                        title: Text("Customer Center", style: TextStyle(color: textColor)),
                        subtitle: Text("Manage your purchase or subscription", style: TextStyle(color: subColor, fontSize: 11)),
                        trailing: Icon(Icons.chevron_right, color: subColor.withOpacity(0.5)),
                        onTap: () async {
                          await RevenueCatUI.presentCustomerCenter();
                          _loadStats();
                        },
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      ),
                      Divider(color: AppColors.divider(context), height: 1),
                    ],
                    ListTile(
                      leading: Icon(Icons.restore, color: subColor),
                      title: Text("Restore Purchases", style: TextStyle(color: textColor)),
                      subtitle: Text("Check for existing App Store licenses", style: TextStyle(color: subColor, fontSize: 11)),
                      trailing: Icon(Icons.chevron_right, color: subColor.withOpacity(0.5)),
                      onTap: () {
                        IapManager().restorePurchases().then((_) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Checking for previous purchases...')),
                          );
                          _loadStats();
                        });
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 48),
              
              _buildSectionHeader(context, "DANGER ZONE", color: Colors.redAccent),
              const SizedBox(height: 16),
              _buildSettingsCard(
                child: ListTile(
                  leading: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                  title: const Text("Reset All Progress", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                  subtitle: Text("Delete timeline and restart vault", style: TextStyle(color: subColor, fontSize: 12)),
                  trailing: Icon(Icons.chevron_right, color: subColor.withOpacity(0.5)),
                  onTap: _showResetConfirmation,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                ),
                borderColor: Colors.redAccent.withOpacity(0.3),
              ),

              const SizedBox(height: 48),
              
              _buildSectionHeader(context, "ABOUT THE VAULT"),
              const SizedBox(height: 16),
              _buildSettingsCard(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
                      title: Text("JLPT Vault", style: TextStyle(color: textColor)),
                      trailing: Text("v1.0.0", style: TextStyle(color: subColor, fontWeight: FontWeight.bold)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    ListTile(
                      leading: Icon(Icons.storage, color: Theme.of(context).colorScheme.primary),
                      title: Text("Database Status", style: TextStyle(color: textColor)),
                      subtitle: Text(
                        _isLoading ? "Loading..." : "Vocab: $_vocabTotal | Grammar: $_grammarTotal",
                        style: TextStyle(color: subColor, fontSize: 12),
                      ),
                      trailing: Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    ),
                    Divider(color: AppColors.divider(context), height: 1),
                    ListTile(
                      leading: Icon(Icons.description_outlined, color: Theme.of(context).colorScheme.primary),
                      title: Text("Terms & Privacy", style: TextStyle(color: textColor)),
                      subtitle: Text("Legal agreements and data safety", style: TextStyle(color: subColor, fontSize: 11)),
                      trailing: Icon(Icons.open_in_new, color: subColor.withOpacity(0.5), size: 18),
                      onTap: () async {
                        final url = Uri.parse('https://kaji-hemopo.github.io/n3-vault-web/');
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: Text(
        title,
        style: TextStyle(
          color: color ?? AppColors.subText(context),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required Widget child, Color? borderColor}) {
    return Glassmorphism.frostedContainer(
      context: context,
      borderRadius: 24,
      padding: EdgeInsets.zero,
      opacity: 0.1,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: borderColor ?? Colors.white12),
        ),
        child: child,
      ),
    );
  }

  Widget _buildDropdownTile({
    required BuildContext context,
    required String title,
    required String subtitle,
    required int value,
    required List<int> options,
    required ValueChanged<int?> onChanged,
    required IconData icon,
  }) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.subText(context), fontSize: 12)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.text(context).withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider(context)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: value,
            dropdownColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.white,
            icon: Icon(Icons.arrow_drop_down, color: AppColors.subText(context)),
            style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.bold),
            onChanged: onChanged,
            items: options.map<DropdownMenuItem<int>>((int val) {
              return DropdownMenuItem<int>(
                value: val,
                child: Text(val.toString(), style: TextStyle(color: AppColors.text(context))),
              );
            }).toList(),
          ),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }

  Widget _buildThemeDropdownTile({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
    required IconData icon,
  }) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.subText(context), fontSize: 12)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.text(context).withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider(context)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            dropdownColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.white,
            icon: Icon(Icons.arrow_drop_down, color: AppColors.subText(context)),
            style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.bold),
            onChanged: onChanged,
            items: options.map<DropdownMenuItem<String>>((String val) {
              return DropdownMenuItem<String>(
                value: val,
                child: Text(val.toUpperCase(), style: TextStyle(color: AppColors.text(context))),
              );
            }).toList(),
          ),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }
}
