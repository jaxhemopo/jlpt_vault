import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'theme_manager.dart';
import 'study_arena.dart';
import 'settings_screen.dart';
import 'iap_manager.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

enum StudyMode { vocab, grammar }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StudyMode _mode = StudyMode.vocab;
  Map<String, int> _stats = {
    'new': 0,
    'vault_remaining': 0,
    'learn': 0,
    'due': 0,
    'total': 0,
    'studied': 0
  };
  bool _isLoading = true;
  int _dailyNewCardLimit = 20;
  bool _hasSeenTutorial = false;

  @override
  void initState() {
    super.initState();
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    try {
      if (mounted) setState(() => _isLoading = true);
      final stats = await DatabaseHelper().getSRSStats(_mode == StudyMode.vocab);
      final prefs = await SharedPreferences.getInstance();
      final dailyLimit = prefs.getInt('daily_new_card_limit') ?? 20;
      final hasSeenTutorial = prefs.getBool('has_seen_tutorial') ?? false;
      if (mounted) {
        setState(() {
          _stats = stats;
          _dailyNewCardLimit = dailyLimit;
          _hasSeenTutorial = hasSeenTutorial;
          _isLoading = false;
        });

        if (!hasSeenTutorial) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showTutorialPopup();
          });
        }
      }
    } catch (e) {
      print("HOME_SCREEN_ERROR: Failed to refresh stats: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _toggleMode(StudyMode mode) {
    if (_mode != mode) {
      setState(() {
        _mode = mode;
      });
      _refreshStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              _buildHeader(),
              const SizedBox(height: 10),
              _buildToggle(),
              const SizedBox(height: 40),
              _buildStatsHUD(),
              const SizedBox(height: 40),
              _buildStartButton(),
              _buildDailyGoal(),
              const SizedBox(height: 30),
              _buildVaultProgress(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVaultProgress() {
    int total = _stats['total'] ?? 0;
    int studied = _stats['studied'] ?? 0;
    double progress = total > 0 ? studied / total : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'TOTAL VAULT PROGRESS',
              style: TextStyle(
                color: AppColors.subText(context),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            Text(
              '$studied / $total',
              style: TextStyle(
                color: AppColors.text(context),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 8,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.text(context).withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OVERVIEW',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'JLPT Study',
              style: TextStyle(
                color: AppColors.text(context),
                fontSize: 28,
                fontWeight: FontWeight.w300,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                Icons.help_outline,
                color: _hasSeenTutorial
                    ? AppColors.text(context)
                    : Theme.of(context).colorScheme.primary,
                size: 26,
              ),
              onPressed: () {
                _showTutorialPopup();
              },
            ),
            IconButton(
              icon: Icon(Icons.settings, color: AppColors.text(context), size: 24),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                ).then((_) => _refreshStats());
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildToggle() {
    return Center(
      child: Container(
        width: 280,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.text(context).withOpacity(0.1),
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.all(4),
        child: Stack(
          children: [
            // Animated Slider
            AnimatedAlign(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              alignment: _mode == StudyMode.vocab
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: Container(
                width: 134,
                decoration: BoxDecoration(
                  color: AppColors.text(context).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppColors.text(context).withOpacity(0.1),
                  ),
                ),
              ),
            ),
            // Buttons
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _toggleMode(StudyMode.vocab),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(
                        'Vocab',
                        style: TextStyle(
                          color: _mode == StudyMode.vocab
                              ? AppColors.text(context)
                              : AppColors.subText(context),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _toggleMode(StudyMode.grammar),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(
                        'Grammar',
                        style: TextStyle(
                          color: _mode == StudyMode.grammar
                              ? AppColors.text(context)
                              : AppColors.subText(context),
                          fontWeight: FontWeight.w500,
                        ),
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

  Widget _buildStatsHUD() {
    return Column(
      children: [
        _buildStatCard(
          icon: Icons.add_circle,
          label: 'New',
          count: _stats['new']!,
          color: Colors.blue,
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          icon: Icons.auto_stories,
          label: 'Learn',
          count: _stats['learn']!,
          color: Colors.redAccent,
        ),
        const SizedBox(height: 16),
        _buildStatCard(
          icon: Icons.event_repeat,
          label: 'Due',
          count: _stats['due']!,
          color: Colors.teal,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required int count,
    required Color color,
    String? subtext,
  }) {
    return Glassmorphism.frostedContainer(
      context: context,
      padding: const EdgeInsets.all(20),
      opacity: 0.1,
      child: Row(
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color.withOpacity(0.8)),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: color.withOpacity(0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _isLoading ? '---' : '$count',
                    style: TextStyle(
                      color: AppColors.text(context),
                      fontSize: 24,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'cards',
                    style: TextStyle(
                      color: AppColors.subText(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (subtext != null && subtext.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtext,
                    style: TextStyle(
                      color: color.withOpacity(0.5),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
          const Spacer(),
          Icon(Icons.chevron_right, color: color.withOpacity(0.3)),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          // GATEKEEPER LOGIC: IF hasActiveAccess() false -> Trigger Paywall
          final hasAccess = await IapManager().hasActiveAccess();
          if (!hasAccess) {
            if (mounted) {
              try {
                Offerings offerings = await Purchases.getOfferings();
                Offering? offering = offerings.all["Vault Access"];
                await RevenueCatUI.presentPaywall(offering: offering);
              } catch (e) {
                print("GATEKEEPER_PAYWALL_ERROR: $e");
                await RevenueCatUI.presentPaywall();
              }
              // Verify after paywall interaction
              final hasAccessNow = await IapManager().hasActiveAccess();
              if (!hasAccessNow) return;
            } else {
              return;
            }
          }

          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => StudyArena(isVocab: _mode == StudyMode.vocab),
              ),
            ).then((_) => _refreshStats());
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          height: 64,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Start Study',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(width: 12),
              Icon(Icons.arrow_forward_ios, size: 18, color: Colors.black),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDailyGoal() {
    return Center(
      child: Text(
        'DAILY NEW CARD LIMIT: $_dailyNewCardLimit',
        style: TextStyle(
          color: AppColors.subText(context).withOpacity(0.5),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
    );
  }

  void _showTutorialPopup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_tutorial', true);
    if (mounted) {
      setState(() {
        _hasSeenTutorial = true;
      });
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: AppColors.divider(context), width: 1),
          ),
          title: Row(
            children: [
              Icon(Icons.school, color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text(
                'How to Use',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Master the JLPT with Spaced Repetition.',
                    style: TextStyle(
                      color: AppColors.text(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildTutorialStep(
                    '1. The Learning Loop',
                    'New cards move from the Vault into your daily study. Learn them once, then review them as they become due.',
                  ),
                  const SizedBox(height: 20),
                  // Diagram row
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.text(context).withOpacity(0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.divider(context)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildDiagramStep(Icons.add_circle, 'New', Colors.blue),
                        Icon(Icons.arrow_forward_ios,
                            color: AppColors.subText(context).withOpacity(0.3), size: 14),
                        _buildDiagramStep(Icons.auto_stories, 'Learn', Colors.redAccent),
                        Icon(Icons.arrow_forward_ios,
                            color: AppColors.subText(context).withOpacity(0.3), size: 14),
                        _buildDiagramStep(Icons.event_repeat, 'Due', Colors.teal),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildTutorialStep(
                    '2. Rate Your Memory',
                    'When you reveal a card, choose how well you remembered it:',
                  ),
                  const SizedBox(height: 12),
                  _buildSrsGuide(),
                  const SizedBox(height: 24),
                  _buildTutorialStep(
                    '3. Personalize Study',
                    'Tap the Gear icon to adjust your daily limits, toggle auto-play audio, or reset your progress if needed.',
                  ),
                  const SizedBox(height: 24),
                  _buildTutorialStep(
                    '4. Reading Support',
                    'Tap the "ABC" toggle in the study arena to reveal furigana for N2+ level Kanji. Note: Kanji expected for N2 level will remain hidden to challenge your memory!',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8.0, bottom: 8.0),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'GOT IT',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTutorialStep(String title, String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(color: AppColors.subText(context), height: 1.5, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildSrsGuide() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.text(context).withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _buildSrsRow('Again', 'Forgot / Wrong. See it again now.', const Color(0xFFff4d4d)),
          Divider(color: AppColors.divider(context), height: 16),
          _buildSrsRow('Hard', 'Struggled. See it again soon.', const Color(0xFFff944d)),
          Divider(color: AppColors.divider(context), height: 16),
          _buildSrsRow('Good', 'Correct. See it again in a few days.', const Color(0xFF4dff88)),
          Divider(color: AppColors.divider(context), height: 16),
          _buildSrsRow('Easy', 'Too easy. See it again much later.', const Color(0xFF4db8ff)),
        ],
      ),
    );
  }

  Widget _buildSrsRow(String label, String desc, Color color) {
    return Row(
      children: [
        Container(
          width: 50,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Text(
            label,
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            desc,
            style: TextStyle(color: AppColors.subText(context).withOpacity(0.7), fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _buildDiagramStep(IconData icon, String label, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color.withOpacity(0.8), size: 32),
        const SizedBox(height: 8),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: color.withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}
