import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'database_helper.dart';
import 'theme_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class StudyArena extends StatefulWidget {
  final bool isVocab;
  const StudyArena({super.key, required this.isVocab});

  @override
  State<StudyArena> createState() => _StudyArenaState();
}

class _StudyArenaState extends State<StudyArena> with SingleTickerProviderStateMixin {
  late Future<List<Map<String, dynamic>>> _cardsFuture;
  List<Map<String, dynamic>> _cards = [];
  int _currentIndex = 0;
  bool _isFlipped = false;
  bool _isProductionMode = true; // EN -> JP (True)
  
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  String? _bgImage;
  late FlutterTts _flutterTts;
  List<Map<String, String>> _japaneseVoices = [];
  bool _isTtsPlaying = false;

  final List<String> _premiumVoiceNames = ['Otoya', 'Kyoko', 'Hattori', 'O-ren'];

  int _newCount = 0;
  int _learnCount = 0;
  int _dueCount = 0;

  int _dailyNewCards = 20;
  int _newCardsStudiedToday = 0;
  int _allowedNewCards = 20;
  bool _showFurigana = false; // Toggle for non-vocab furigana


  @override
  void initState() {
    super.initState();
    _cardsFuture = _loadInitialCards();
    _cardsFuture.then((value) {
      if (mounted) setState(() => _cards = value);
    });

    DatabaseHelper().getSRSStats(widget.isVocab).then((stats) {
      if (mounted) {
        setState(() {
          _newCount = stats['new'] as int? ?? 0;
          _learnCount = stats['learn'] as int? ?? 0;
          _dueCount = stats['due'] as int? ?? 0;
        });
      }
    });

    _initTts();
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _flipAnimation = Tween<double>(begin: 0, end: pi).animate(
      CurvedAnimation(parent: _flipController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initTts() async {
    _flutterTts = FlutterTts();
    await _flutterTts.setLanguage("ja-JP");
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setSharedInstance(true);
    await _flutterTts.setIosAudioCategory(
      IosTextToSpeechAudioCategory.playback,
      [
        IosTextToSpeechAudioCategoryOptions.allowBluetooth,
        IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
      ],
      IosTextToSpeechAudioMode.defaultMode,
    );

    // Fetch and filter Japanese voices
    List<dynamic> voices = await _flutterTts.getVoices;
    
    // Debug print
    var debugJpVoices = voices.where((voice) =>
        voice['locale']?.toString().contains('ja') == true ||
        voice['locale']?.toString().contains('JP') == true).toList();
    print("🎙️ AVAILABLE JP VOICES: $debugJpVoices");

    _japaneseVoices = voices.where((voice) {
      bool isJp = voice['locale']?.toString().contains('ja') == true ||
                  voice['locale']?.toString().contains('JP') == true;
      if (!isJp) return false;
      
      String voiceName = voice['name']?.toString() ?? "";
      return _premiumVoiceNames.any((premium) => voiceName.contains(premium));
    }).map((voice) => {
      "name": voice["name"].toString(),
      "locale": voice["locale"].toString()
    }).toList();

    // Load user preference
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _showFurigana = prefs.getBool('show_all_furigana') ?? false;
      });
    }

    _flutterTts.setStartHandler(() {
      if (mounted) setState(() => _isTtsPlaying = true);
    });
    _flutterTts.setCompletionHandler(() {
      if (mounted) setState(() => _isTtsPlaying = false);
    });
    _flutterTts.setCancelHandler(() {
      if (mounted) setState(() => _isTtsPlaying = false);
    });
    _flutterTts.setErrorHandler((msg) {
      if (mounted) setState(() => _isTtsPlaying = false);
    });
  }

  Future<void> _playRandomVoiceTTS(String text) async {
    if (_japaneseVoices.isNotEmpty) {
      final randomVoice = _japaneseVoices[Random().nextInt(_japaneseVoices.length)];
      await _flutterTts.setVoice({"name": randomVoice["name"]!, "locale": randomVoice["locale"]!});
    }
    await _flutterTts.speak(text);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bgImage == null) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      _bgImage = BackgroundManager.getRandomBackground(isDark);
    }
  }

  Future<List<Map<String, dynamic>>> _loadInitialCards() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    int dailyNewCardLimit = prefs.getInt('daily_new_card_limit') ?? 20;
    int dailyReviewLimit = prefs.getInt('daily_review_limit') ?? 100;
    String studiedKey = widget.isVocab ? 'vocab_new_cards_studied_today' : 'grammar_new_cards_studied_today';
    int newCardsStudiedToday = prefs.getInt(studiedKey) ?? 0;
    String lastStudyDate = prefs.getString('last_study_date') ?? '';

    String today = DateTime.now().toIso8601String().split('T')[0];
    if (lastStudyDate != today) {
      newCardsStudiedToday = 0;
      await prefs.setInt('vocab_new_cards_studied_today', 0);
      await prefs.setInt('grammar_new_cards_studied_today', 0);
      await prefs.setString('last_study_date', today);
    }

    if (mounted) {
      setState(() {
        _dailyNewCards = dailyNewCardLimit;
        _newCardsStudiedToday = newCardsStudiedToday;
        _allowedNewCards = (_dailyNewCards - _newCardsStudiedToday).clamp(0, _dailyNewCards);
      });
    }

    final db = DatabaseHelper();
    // 1. Fetch complete queue: Learning -> Review -> New (capped)
    List<Map<String, dynamic>> cardsRaw = await db.getStudySessionCards(widget.isVocab);
    
    // 3. If Vocab, attach first example sentence
    List<Map<String, dynamic>> finalCards = [];
    if (widget.isVocab) {
      for (var cardRaw in cardsRaw) {
        final card = Map<String, dynamic>.from(cardRaw);
        final examples = await db.getExampleSentences(card['id']);
        if (examples.isNotEmpty) {
          int reps = (card['repetition_count'] as int?) ?? 0;
          int index = reps % examples.length;
          card['example_jp'] = examples[index]['sentence_jp'];
          card['example_en'] = examples[index]['sentence_en'];
        }
        finalCards.add(card);
      }
    } else {
      finalCards = cardsRaw;
    }
    
    return finalCards;
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _flipCard() {
    if (_isFlipped) {
      _flipController.reverse();
    } else {
      _flipController.forward();
    }
    setState(() => _isFlipped = !_isFlipped);
  }

  void _nextCard(String rating) async {
    await _flutterTts.stop(); // Stop audio if still playing

    if (_currentIndex < _cards.length) {
      final card = _cards[_currentIndex];
      final cardId = card['id'];
      
      // Decrement UI Counters instantly
      setState(() {
        final state = card['state'] ?? 'new';
        final reps = (card['repetition_count'] as int?) ?? 0;

        if (state == 'new') {
          _newCount = max(0, _newCount - 1);
          _newCardsStudiedToday++;
          _allowedNewCards = (_dailyNewCards - _newCardsStudiedToday).clamp(0, _dailyNewCards);
          SharedPreferences.getInstance().then((prefs) {
            String studiedKey = widget.isVocab ? 'vocab_new_cards_studied_today' : 'grammar_new_cards_studied_today';
            prefs.setInt(studiedKey, _newCardsStudiedToday);
          });
          
          if (rating != 'easy') {
            _learnCount++; // Enters learning phase
          }
        } else if (state == 'learning' || state == 'relearning') {
          if (rating == 'easy' || (rating == 'good' && reps > 0)) {
            _learnCount = max(0, _learnCount - 1); // Graduates
          }
        } else {
          // 'review' or due card
          _dueCount = max(0, _dueCount - 1);
          if (rating == 'again') {
            _learnCount++; // Drops into relearning
          }
        }
      });

      // Update SRS in background
      DatabaseHelper().updateSRSProgress(widget.isVocab, cardId, rating);

      // Re-queue card if marked as 'again' so user must review it
      if (rating == 'again') {
        final reQueueCard = Map<String, dynamic>.from(card);
        reQueueCard['state'] = 'learning';
        
        // Simulates 1m delay: Insert it 3-5 cards away
        int offset = 3 + (DateTime.now().millisecond % 3);
        int insertIndex = _currentIndex + offset;
        if (insertIndex > _cards.length) {
          insertIndex = _cards.length;
        }
        _cards.insert(insertIndex, reQueueCard);
      }
    }

    if (_currentIndex < _cards.length - 1) {
      _flipController.reset();
      setState(() {
        _currentIndex++;
        _isFlipped = false;
      });
    } else {
      // Session complete
      Navigator.pop(context);
    }
  }

  void _showFlagCardDialog() {
    if (_cards.isEmpty || _currentIndex >= _cards.length) return;
    
    final card = _cards[_currentIndex];
    final String cardInfo = widget.isVocab 
      ? "Vocab: ${card['kanji'] ?? card['reading']}" 
      : "Grammar: ${card['grammar_name'] ?? card['sentence_jp']}";
    
    final TextEditingController _msgController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: AppColors.divider(context), width: 1),
        ),
        title: Text(
          "Flag this Card?",
          style: TextStyle(color: AppColors.text(context), fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Reporting: $cardInfo",
              style: TextStyle(color: AppColors.subText(context), fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _msgController,
              maxLines: 4,
              style: TextStyle(color: AppColors.text(context), fontSize: 14),
              decoration: InputDecoration(
                hintText: "Enter the issue or comment here...",
                hintStyle: TextStyle(color: AppColors.subText(context).withOpacity(0.5), fontSize: 14),
                filled: true,
                fillColor: AppColors.text(context).withOpacity(0.05),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.divider(context))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(context).colorScheme.primary)),
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
            onPressed: () async {
              final String userMsg = _msgController.text.trim();
              if (userMsg.isEmpty) return;
              
              final Uri emailLaunchUri = Uri(
                scheme: 'mailto',
                path: 'kaji.hemopo@gmail.com',
                query: encodeQueryParameters(<String, String>{
                  'subject': 'N3 Vault Card Flagged.',
                  'body': 'Card: $cardInfo\n\nIssue:\n$userMsg',
                }),
              );

              if (await canLaunchUrl(emailLaunchUri)) {
                await launchUrl(emailLaunchUri);
              }
              
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Constructing report email...')),
              );
            },
            child: Text(
              "SEND",
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  String? encodeQueryParameters(Map<String, String> params) {
    return params.entries
        .map((MapEntry<String, String> e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  @override
  Widget build(BuildContext context) {
    // Background is now persisted via _bgImage set in didChangeDependencies

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.close, color: AppColors.text(context)),
          onPressed: () => Navigator.pop(context),
        ),
        title: _buildProgressBar(),
        actions: [
          IconButton(
            tooltip: "Toggle Furigana",
            icon: Icon(
              Icons.abc,
              size: 38,
              color: _showFurigana ? AppColors.text(context) : AppColors.subText(context),
            ),
            onPressed: () async {
              SharedPreferences prefs = await SharedPreferences.getInstance();
              bool newVal = !_showFurigana;
              await prefs.setBool('show_all_furigana', newVal);
              setState(() => _showFurigana = newVal);
            },
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: AppColors.subText(context)),
            color: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.divider(context)),
            ),
            onSelected: (value) {
              if (value == 'flag') _showFlagCardDialog();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'flag',
                child: Row(
                  children: [
                    const Icon(Icons.flag_outlined, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 12),
                    Text("Flag Card", style: TextStyle(color: AppColors.text(context), fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _bgImage != null 
              ? Image.asset(_bgImage!, fit: BoxFit.cover) 
              : Container(color: Colors.black),
          ),
          SafeArea(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _cardsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary));
                }
                if (_cards.isEmpty || _currentIndex >= _cards.length) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Glassmorphism.frostedContainer(
                        context: context,
                        borderRadius: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                        opacity: 0.15,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.check_circle_outline, size: 80, color: Colors.greenAccent),
                            const SizedBox(height: 24),
                            Text(
                              (_newCardsStudiedToday >= _dailyNewCards)
                                  ? "You have hit your new card limit of $_dailyNewCards and have no reviews due. Check back later!"
                                  : "Vault Cleared! No cards due.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.text(context),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(height: 32),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.text(context).withOpacity(0.05),
                                foregroundColor: AppColors.text(context),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                                elevation: 0,
                                side: BorderSide(color: AppColors.divider(context)),
                              ),
                              onPressed: () => Navigator.pop(context),
                              child: const Text("RETURN TO HOME", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
                            )
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    _buildSessionCounters(),
                    const SizedBox(height: 8),
                    _buildFlipCard(),
                    const SizedBox(height: 32),
                    _buildActionBar(),
                    const SizedBox(height: 40),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCounters() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text("$_newCount", style: const TextStyle(color: Colors.blueAccent, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(width: 32),
          Text("$_learnCount", style: const TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(width: 32),
          Text("$_dueCount", style: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    double progress = _cards.isEmpty ? 0 : (_currentIndex + 1) / _cards.length;
    return Container(
      height: 8,
      width: 200,
      decoration: BoxDecoration(
        color: AppColors.text(context).withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: progress,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }

  Widget _buildProductionToggle() {
    return GestureDetector(
      onTap: () {
        setState(() => _isProductionMode = !_isProductionMode);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.text(context).withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.divider(context)),
        ),
        child: Text(
          _isProductionMode ? "Writing" : "Reading",
          style: TextStyle(color: AppColors.subText(context), fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildFlipCard() {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: AnimatedBuilder(
          animation: _flipAnimation,
          builder: (context, child) {
            final angle = _flipAnimation.value;
            final isFront = angle <= pi / 2;
            
            return Transform(
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(angle),
              alignment: Alignment.center,
              child: GestureDetector(
                onTap: _isFlipped ? null : _flipCard,
                child: isFront
                  ? _buildCardSide(true)
                  : Transform(
                      transform: Matrix4.identity()..rotateY(pi),
                      alignment: Alignment.center,
                      child: _buildCardSide(false),
                    ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCardSide(bool isFront) {
    if (_cards.isEmpty || _currentIndex >= _cards.length) {
      return const SizedBox.shrink(); // Handled by inbox zero screen
    }
    final card = _cards[_currentIndex];
    
    return Glassmorphism.frostedContainer(
      context: context,
      borderRadius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      opacity: 0.15,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        alignment: Alignment.center,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isVocab) ...[
                _buildVocabContent(card, isFront)
              ] else ...[
                _buildGrammarContent(card, isFront)
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVocabContent(Map<String, dynamic> card, bool isFront) {
    if (isFront) {
      if (card['example_jp'] != null) {
        String displaySentence = card['example_jp'];
        
        return Column(
          children: [
            FuriganaText(
              text: displaySentence,
              showAllFurigana: _showFurigana,
              isTargetHidden: true,
              target: card['kanji'] ?? card['reading'],
              style: TextStyle(color: AppColors.text(context), fontSize: 26),
            ),
            const SizedBox(height: 32),
            Text(
              card['kanji'] ?? card['reading'],
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.text(context),
                fontSize: 56,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
          ],
        );
      } else {
        return Text(
          card['kanji'] ?? card['reading'],
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.text(context), fontSize: 56, fontWeight: FontWeight.bold),
        );
      }
    } else {
      // BACK OF CARD
      final hasExample = card['example_jp'] != null;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasExample) ...[
            FuriganaText(
              text: card['example_jp'],
              showAllFurigana: _showFurigana,
              isTargetHidden: false,
              target: card['kanji'],
              style: TextStyle(color: AppColors.subText(context), fontSize: 20),
            ),
            const SizedBox(height: 8),
            IconButton(
              icon: Icon(
                _isTtsPlaying ? Icons.pause : Icons.volume_up,
                color: AppColors.subText(context),
                size: 32,
              ),
              onPressed: () {
                if (_isTtsPlaying) {
                  _flutterTts.stop();
                } else {
                  String cleanText = card['example_jp'].replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), '');
                  _playRandomVoiceTTS(cleanText);
                }
              },
            ),
            const SizedBox(height: 32),
          ],
          Text(
            card['kanji'] ?? card['reading'],
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.text(context),
              fontSize: 48,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            card['reading'],
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            card['english_meaning'],
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.text(context),
              fontSize: 28,
              fontWeight: FontWeight.w400,
            ),
          ),
          if (hasExample) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Divider(color: AppColors.divider(context)),
            ),
            Text(
              card['example_en'],
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.subText(context).withOpacity(0.5),
                fontSize: 16,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      );
    }
  }

  Widget _buildGrammarContent(Map<String, dynamic> card, bool isFront) {
    if (_isProductionMode) {
      if (isFront) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Translate this sentence:",
              style: TextStyle(color: AppColors.subText(context), fontSize: 14, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                card['sentence_en'] ?? "No English Sentence Found",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.text(context),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.text(context).withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.divider(context)),
              ),
              child: Text(
                "Grammar: ${card['grammar_name'] ?? 'Rule'}",
                style: TextStyle(color: AppColors.text(context), fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      } else {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FuriganaText(
              text: card['sentence_jp'],
              showAllFurigana: _showFurigana,
              isTargetHidden: false,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.text(context), fontSize: 26),
            ),
            const SizedBox(height: 8),
            IconButton(
              icon: Icon(
                _isTtsPlaying ? Icons.pause_circle_outline : Icons.volume_up_outlined,
                color: AppColors.subText(context),
                size: 32,
              ),
              onPressed: () {
                if (_isTtsPlaying) {
                  _flutterTts.stop();
                } else {
                  String cleanText = card['sentence_jp'].replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), '');
                  _playRandomVoiceTTS(cleanText);
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Divider(color: AppColors.divider(context)),
            ),
            Text(
              card['grammar_meaning'] ?? "Grammar Rule Meaning",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.text(context), fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (card['rule_structure'] != null) ...[
              const SizedBox(height: 12),
              Text(
                card['rule_structure'],
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subText(context).withOpacity(0.5), fontSize: 14),
              ),
            ]
          ],
        );
      }
    } else {
      // READING MODE
      if (isFront) {
        return FuriganaText(
          text: card['cloze_sentence_jp'] ?? card['sentence_jp'],
          showAllFurigana: _showFurigana,
          isTargetHidden: true,
          target: card['cloze_answer'],
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.text(context), fontSize: 28),
        );
      } else {
        return Column(
          children: [
            FuriganaText(
              text: card['sentence_jp'],
              showAllFurigana: _showFurigana,
              isTargetHidden: false,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subText(context), fontSize: 22),
            ),
            const SizedBox(height: 8),
            IconButton(
              icon: Icon(
                _isTtsPlaying ? Icons.pause_circle_outline : Icons.volume_up_outlined,
                color: AppColors.subText(context),
                size: 32,
              ),
              onPressed: () {
                if (_isTtsPlaying) {
                  _flutterTts.stop();
                } else {
                  String cleanText = card['sentence_jp'].replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), '');
                  _playRandomVoiceTTS(cleanText);
                }
              },
            ),
            const Divider(height: 40, color: Colors.transparent),
            Text(
              card['sentence_en'],
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.text(context), fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Text(
              card['grammar_name'] ?? "",
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            Text(
              card['grammar_meaning'] ?? "",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subText(context), fontSize: 13),
            ),
          ],
        );
      }
    }
  }

  Widget _buildActionBar() {
    if (!_isFlipped) {
      return Text(
        "Tap to reveal",
        style: TextStyle(color: AppColors.subText(context).withOpacity(0.5), fontSize: 14, letterSpacing: 1),
      );
    }

    final card = _cards[_currentIndex];
    final intervals = DatabaseHelper().getSRSIntervals(card);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildSRSButton("Again", intervals['again']!, const Color(0xFFff4d4d), () {
            HapticFeedback.heavyImpact();
            _nextCard("again");
          }),
          const SizedBox(width: 12),
          _buildSRSButton("Hard", intervals['hard']!, const Color(0xFFff944d), () {
            HapticFeedback.mediumImpact();
            _nextCard("hard");
          }),
          const SizedBox(width: 12),
          _buildSRSButton("Good", intervals['good']!, const Color(0xFF4dff88), () {
            HapticFeedback.lightImpact();
            _nextCard("good");
          }),
          const SizedBox(width: 12),
          _buildSRSButton("Easy", intervals['easy']!, const Color(0xFF4db8ff), () {
            HapticFeedback.lightImpact();
            _nextCard("easy");
          }),
        ],
      ),
    );
  }

  Widget _buildSRSButton(String label, String interval, Color color, VoidCallback onTap) {
    return Column(
      children: [
        Text(interval, style: TextStyle(color: color.withOpacity(0.7), fontSize: 10, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0x88000000), // Semi-transparent black
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withOpacity(0.3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }
}

class FuriganaText extends StatelessWidget {
  final String text;
  final bool showAllFurigana;
  final bool isTargetHidden;
  final String? target;
  final TextStyle? style;
  final TextAlign textAlign;

  const FuriganaText({
    super.key,
    required this.text,
    this.showAllFurigana = false,
    this.isTargetHidden = false,
    this.target,
    this.style,
    this.textAlign = TextAlign.center,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    final effectiveStyle = (style ?? const TextStyle(fontSize: 24)).copyWith(
      color: style?.color ?? AppColors.text(context),
    );

    // 1. Prepare Target Data
    final cleanTarget = target?.replaceAll(RegExp(r'[\[\]\(\)]'), '') ?? '';
    final kanjiRegex = RegExp(r'[一-龠]');
    final targetKanji = cleanTarget.split('').where((c) => kanjiRegex.hasMatch(c)).toSet();

    // Find exact matches for the full target word (handles Kana words and unconjugated words)
    List<Match> exactMatches = [];
    if (target != null && target!.isNotEmpty) {
      try {
        String regexSource = target!
            .split('')
            .map((char) => '${RegExp.escape(char)}(?:[\\[\\(][^\\]\\)]+[\\]\\)])?')
            .join('');
        RegExp targetRegex = RegExp(regexSource);
        exactMatches = targetRegex.allMatches(text).toList();
      } catch (e) {
        print("FURIGANA_TEXT_ERROR: Failed to create target regex for '$target': $e");
      }
    }

    bool isIndexInExactMatch(int index) {
      for (var m in exactMatches) {
        if (index >= m.start && index < m.end) return true;
      }
      return false;
    }

    // 2. Parse the text for 漢字[ふりがな] or Word(reading) patterns
    final regex = RegExp(r'([^ \s\[\(\n\r]+)[\[\(]([^\]\)]+)[\]\)]');
    final matches = regex.allMatches(text);

    List<InlineSpan> spans = [];
    int lastMatchEnd = 0;

    // Helper to build spans with highlighting character-by-character
    List<InlineSpan> buildHighlightedSpans(String plainText, int globalOffset) {
      List<InlineSpan> subSpans = [];
      for (int i = 0; i < plainText.length; i++) {
        String char = plainText[i];
        
        bool isExactMatch = isIndexInExactMatch(globalOffset + i);
        bool isTargetKanji = targetKanji.contains(char); // Fallback for conjugated words

        bool highlight = isExactMatch || isTargetKanji;

        subSpans.add(TextSpan(
          text: char,
          style: highlight
              ? effectiveStyle.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                )
              : effectiveStyle,
        ));
      }
      return subSpans;
    }

    for (var match in matches) {
      // Add plain text before match
      if (match.start > lastMatchEnd) {
        spans.addAll(buildHighlightedSpans(text.substring(lastMatchEnd, match.start), lastMatchEnd));
      }

      final kanjiPart = match.group(1)!;
      final furiganaPart = match.group(2)!;
      
      // Pass the kanjiPart through the character-by-character highlighter
      spans.addAll(buildHighlightedSpans(kanjiPart, match.start));
      
      // Determine if this furigana block should be hidden:
      // We explicitly check if any Kanji character taking this furigana is the target.
      bool blockContainsTargetKanji = false;
      for (int i = 0; i < kanjiPart.length; i++) {
        String c = kanjiPart[i];
        if (kanjiRegex.hasMatch(c)) {
          if (isIndexInExactMatch(match.start + i) || targetKanji.contains(c)) {
            blockContainsTargetKanji = true;
            break;
          }
        }
      }

      bool hideThisFurigana = blockContainsTargetKanji ? isTargetHidden : !showAllFurigana;

      if (!hideThisFurigana) {
        spans.add(TextSpan(
          text: "($furiganaPart)",
          style: effectiveStyle.copyWith(
              fontSize: (effectiveStyle.fontSize ?? 24) * 0.6,
              color: effectiveStyle.color?.withOpacity(0.6),
              fontWeight: FontWeight.normal,
          ),
        ));
      }
      
      lastMatchEnd = match.end;
    }

    // Add remaining plain text
    if (lastMatchEnd < text.length) {
      spans.addAll(buildHighlightedSpans(text.substring(lastMatchEnd), lastMatchEnd));
    }

    return RichText(
      textAlign: textAlign,
      text: TextSpan(style: effectiveStyle, children: spans),
    );
  }
}
