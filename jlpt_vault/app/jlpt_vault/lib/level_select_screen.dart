import 'package:flutter/material.dart';
import 'database_helper.dart';
import 'theme_manager.dart';

/// First-run (or settings) JLPT level chooser. N1 is disabled until data exists.
class LevelSelectScreen extends StatefulWidget {
  final bool isChangingLevel;
  final VoidCallback onLevelChosen;

  const LevelSelectScreen({
    super.key,
    this.isChangingLevel = false,
    required this.onLevelChosen,
  });

  @override
  State<LevelSelectScreen> createState() => _LevelSelectScreenState();
}

class _LevelSelectScreenState extends State<LevelSelectScreen> {
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

  Future<void> _pickLevel(BuildContext context, int level) async {
    final current = DatabaseHelper().selectedLevel;
    if (current == level && widget.isChangingLevel) {
      if (context.mounted) Navigator.of(context).pop();
      return;
    }
    try {
      await DatabaseHelper().openForLevel(level);
    } catch (e, st) {
      debugPrint('LEVEL_SELECT: openForLevel failed: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open study data (N$level). Please try again or reinstall.')),
        );
      }
      return;
    }
    widget.onLevelChosen();
    if (context.mounted && widget.isChangingLevel) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final textColor = AppColors.text(context);
    final subColor = AppColors.subText(context);

    Widget body = SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.isChangingLevel) ...[
              Text(
                'JLPT Vault',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose your level. Study progress and SRS are kept per level.',
                textAlign: TextAlign.center,
                style: TextStyle(color: subColor, fontSize: 14, height: 1.35),
              ),
              const SizedBox(height: 36),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                'Change JLPT level',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'This switches the bundled database for your session. Progress stays on each level’s data file.',
                textAlign: TextAlign.center,
                style: TextStyle(color: subColor, fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 28),
            ],
            _LevelButton(
              label: 'N5',
              subtitle: 'Beginner',
              onTap: () => _pickLevel(context, 5),
            ),
            const SizedBox(height: 12),
            _LevelButton(
              label: 'N4',
              subtitle: 'Elementary',
              onTap: () => _pickLevel(context, 4),
            ),
            const SizedBox(height: 12),
            _LevelButton(
              label: 'N3',
              subtitle: 'Intermediate',
              onTap: () => _pickLevel(context, 3),
            ),
            const SizedBox(height: 12),
            _LevelButton(
              label: 'N2',
              subtitle: 'Upper intermediate',
              onTap: () => _pickLevel(context, 2),
            ),
            const SizedBox(height: 12),
            _LevelButton(
              label: 'N1',
              subtitle: 'Advanced',
              onTap: () => _pickLevel(context, 1),
            ),
          ],
        ),
      ),
    );

    final stackBody = Stack(
      fit: StackFit.expand,
      children: [
        if (_bgImage != null)
          Image.asset(
            _bgImage!,
            fit: BoxFit.cover,
          ),
        body,
      ],
    );

    if (widget.isChangingLevel) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.close, color: textColor),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text('Level', style: TextStyle(color: textColor, fontSize: 16)),
          centerTitle: true,
        ),
        body: stackBody,
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: stackBody,
    );
  }
}

class _LevelButton extends StatelessWidget {
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  const _LevelButton({
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = AppColors.text(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: Glassmorphism.frostedContainer(
          context: context,
          borderRadius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          opacity: enabled ? 0.12 : 0.06,
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  subtitle,
                  style: TextStyle(
                    color: AppColors.subText(context),
                    fontSize: 14,
                  ),
                ),
              ),
              if (enabled)
                Icon(Icons.chevron_right, color: AppColors.subText(context))
              else
                Text(
                  'Soon',
                  style: TextStyle(
                    color: AppColors.subText(context).withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
