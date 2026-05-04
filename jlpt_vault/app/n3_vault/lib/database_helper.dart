import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DatabaseHelper {
  static const String selectedJlptLevelKey = 'selected_jlpt_level';

  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  int? _activeLevel;

  /// Ensures only one open/init runs at a time; await before close/reopen.
  Future<Database>? _dbOpenFuture;

  /// Bumped when the on-disk DB changes (level switch or refresh); home listens to refresh stats.
  static final ValueNotifier<int> activeLevelRevision = ValueNotifier<int>(0);

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  int? get selectedLevel => _activeLevel;

  String _grammarTag() {
    final l = _activeLevel;
    if (l == null) return 'N3';
    return 'N$l';
  }

  String _dbFileName(int level) {
    switch (level) {
      case 5:
        return 'jlpt_vault_n5.db';
      case 4:
        return 'jlpt_vault_n4.db';
      case 3:
        return 'jlpt_vault_n3.db';
      case 2:
        return 'jlpt_vault_n2.db';
      case 1:
        return 'jlpt_vault_n1.db';
      default:
        throw ArgumentError('Unsupported JLPT level: $level');
    }
  }

  String _assetRelativePath(int level) {
    switch (level) {
      case 5:
      case 4:
        return join('assets', 'vault_n45.db');
      case 3:
        return join('assets', 'vault_n3.db');
      case 2:
        return join('assets', 'vault_n2.db');
      case 1:
        return join('assets', 'vault_n1.db');
      default:
        throw ArgumentError('Unsupported JLPT level: $level');
    }
  }

  /// Call after the user picks N5–N1. Closes any open DB, updates prefs, copies/opens the right asset.
  Future<void> openForLevel(int level) async {
    if (level < 1 || level > 5) {
      throw ArgumentError('openForLevel expects 1–5, got $level');
    }
    await _awaitInFlightOpen();
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    _activeLevel = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(selectedJlptLevelKey, '$level');
    // After DB is ready only — avoids HomeScreen refreshing on a closed DB / double _initDB.
    await _startAndAwaitOpen();
    activeLevelRevision.value++;
  }

  Future<void> _awaitInFlightOpen() async {
    if (_dbOpenFuture == null) return;
    try {
      await _dbOpenFuture;
    } catch (_) {}
    _dbOpenFuture = null;
  }

  Future<Database> _startAndAwaitOpen() async {
    _dbOpenFuture ??= _initDB().then((db) {
      _database = db;
      return db;
    }).whenComplete(() {
      _dbOpenFuture = null;
    });
    return _dbOpenFuture!;
  }

  Future<void> _restoreLevelFromPrefs() async {
    if (_activeLevel != null) return;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(selectedJlptLevelKey);
    final parsed = int.tryParse(s ?? '');
    if (parsed != null && parsed >= 1 && parsed <= 5) {
      _activeLevel = parsed;
    }
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    await _restoreLevelFromPrefs();
    if (_activeLevel == null) {
      throw StateError(
          'JLPT level not selected. Show LevelSelectScreen before using the database.');
    }
    return _startAndAwaitOpen();
  }

  Future<Database> _initDB() async {
    try {
      final level = _activeLevel;
      if (level == null) {
        throw StateError('openForLevel must run before _initDB');
      }
      final dbPath = await getDatabasesPath();
      final filename = _dbFileName(level);
      final path = join(dbPath, filename);

      final exists = await databaseExists(path);

      if (!exists) {
        await _copyFromAssets(path, level);
      } else {
        print("DATABASE_HELPER: Opening existing database at $path");
      }

      var db = await openDatabase(path);

      final tableCheck = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='grammar_cards'");
      if (tableCheck.isEmpty) {
        print(
            "DATABASE_HELPER: Core tables missing (grammar_cards), forcing re-copy from assets...");
        await db.close();
        await _copyFromAssets(path, level);
        db = await openDatabase(path);
      }

      print("DATABASE_HELPER: Database opened successfully (JLPT N$level)");

      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_grammar_progress (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          grammar_id INTEGER UNIQUE,
          state TEXT DEFAULT 'new',
          interval_days INTEGER DEFAULT 0,
          ease_factor REAL DEFAULT 2.5,
          repetition_count INTEGER DEFAULT 0,
          lapses INTEGER DEFAULT 0,
          last_reviewed_at TEXT,
          next_review_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY(grammar_id) REFERENCES grammar_rules(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_vocabulary_progress (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          vocab_id INTEGER UNIQUE,
          state TEXT DEFAULT 'new',
          interval_days INTEGER DEFAULT 0,
          ease_factor REAL DEFAULT 2.5,
          repetition_count INTEGER DEFAULT 0,
          lapses INTEGER DEFAULT 0,
          last_reviewed_at TEXT,
          next_review_at TEXT DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY(vocab_id) REFERENCES vocabulary(id) ON DELETE CASCADE
        )
      ''');
      print("DATABASE_HELPER: Schema verified");

      return db;
    } catch (e, stack) {
      print("DATABASE_HELPER_ERROR: Failed to initialize database: $e");
      print(stack);
      rethrow;
    }
  }

  Future<void> _copyFromAssets(String path, int level) async {
    print("DATABASE_HELPER: Copying database from assets to $path");
    try {
      await Directory(dirname(path)).create(recursive: true);
      final assetPath = _assetRelativePath(level);
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(path).writeAsBytes(bytes, flush: true);
      print("DATABASE_HELPER: Copy successful ($assetPath)");
    } catch (e) {
      print("DATABASE_HELPER_ERROR: Copy from assets failed: $e");
      rethrow;
    }
  }

  Future<void> refreshDatabase() async {
    await _restoreLevelFromPrefs();
    final level = _activeLevel;
    if (level == null) {
      throw StateError('Cannot refresh without a selected level');
    }
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, _dbFileName(level));

      await _awaitInFlightOpen();
      if (_database != null) {
        await _database!.close();
        _database = null;
      }

      await _copyFromAssets(path, level);
      _database = await openDatabase(path);
      activeLevelRevision.value++;
      print("DATABASE_HELPER: Database refreshed successfully");
    } catch (e) {
      print("DATABASE_HELPER_ERROR: Refresh failed: $e");
      rethrow;
    }
  }

  /// Get SRS Stats: New, Learn, Due, Total
  Future<Map<String, int>> getSRSStats(bool isVocab) async {
    print("DATABASE_HELPER: getSRSStats started (isVocab: $isVocab)");
    final level = _activeLevel;
    if (level == null) {
      await _restoreLevelFromPrefs();
    }
    final jlpt = _activeLevel;
    if (jlpt == null) {
      return {'new': 0, 'vault_remaining': 0, 'learn': 0, 'due': 0, 'total': 0, 'studied': 0};
    }
    final grammarLv = _grammarTag();

    try {
      final db = await database;
      final progressTable = isVocab ? 'user_vocabulary_progress' : 'user_grammar_progress';
      final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';

      final statusCounts = await db.rawQuery('''
        SELECT 
          SUM(CASE WHEN (p.state = 'learning' OR p.state = 'relearning') AND p.next_review_at <= CURRENT_TIMESTAMP THEN 1 ELSE 0 END) as learn_count,
          SUM(CASE WHEN p.state = 'review' AND p.next_review_at <= CURRENT_TIMESTAMP THEN 1 ELSE 0 END) as due_count
        FROM $progressTable p
        ${isVocab ? 'INNER JOIN vocabulary v ON v.id = p.vocab_id AND v.jlpt_level = ?' : '''
        INNER JOIN grammar_cards c ON c.id = p.grammar_id
        INNER JOIN grammar_rules r ON c.grammar_id = r.id AND r.grammar_level = ?
        '''}
      ''', [isVocab ? jlpt : grammarLv]);

      int learnC = 0, dueC = 0;
      if (statusCounts.isNotEmpty) {
        learnC = (statusCounts.first['learn_count'] as num?)?.toInt() ?? 0;
        dueC = (statusCounts.first['due_count'] as num?)?.toInt() ?? 0;
      }

      int totalVault = 0;
      if (isVocab) {
        final totalRecords = await db.rawQuery(
            'SELECT COUNT(*) as count FROM $contentTable WHERE jlpt_level = ?', [jlpt]);
        if (totalRecords.isNotEmpty) {
          totalVault = (totalRecords.first['count'] as num?)?.toInt() ?? 0;
        }
      } else {
        final totalRecords = await db.rawQuery('''
          SELECT COUNT(*) as count FROM grammar_cards c
          INNER JOIN grammar_rules r ON c.grammar_id = r.id
          WHERE c.audit_status = 'verified' AND r.grammar_level = ?
        ''', [grammarLv]);
        if (totalRecords.isNotEmpty) {
          totalVault = (totalRecords.first['count'] as num?)?.toInt() ?? 0;
        }
      }

      int studied = 0;
      if (isVocab) {
        final studiedRecords = await db.rawQuery('''
          SELECT COUNT(*) as count FROM $progressTable p
          INNER JOIN vocabulary v ON v.id = p.vocab_id AND v.jlpt_level = ?
        ''', [jlpt]);
        if (studiedRecords.isNotEmpty) {
          studied = (studiedRecords.first['count'] as num?)?.toInt() ?? 0;
        }
      } else {
        final studiedRecords = await db.rawQuery('''
          SELECT COUNT(*) as count FROM $progressTable p
          INNER JOIN grammar_cards c ON c.id = p.grammar_id
          INNER JOIN grammar_rules r ON c.grammar_id = r.id AND r.grammar_level = ?
        ''', [grammarLv]);
        if (studiedRecords.isNotEmpty) {
          studied = (studiedRecords.first['count'] as num?)?.toInt() ?? 0;
        }
      }

      int remainingNew = totalVault - studied;

      final prefs = await SharedPreferences.getInstance();
      int dailyLimit = prefs.getInt('daily_new_card_limit') ?? 20;
      String studiedKey =
          isVocab ? 'vocab_new_cards_studied_today' : 'grammar_new_cards_studied_today';
      int studiedToday = prefs.getInt(studiedKey) ?? 0;
      int allowedNewCards = dailyLimit - studiedToday;
      if (allowedNewCards < 0) allowedNewCards = 0;

      int displayNew = allowedNewCards > remainingNew ? remainingNew : allowedNewCards;

      int displayTotal = totalVault;
      int displayStudied = studied;

      if (isVocab) {
        final sentenceTotal = await db.rawQuery('''
          SELECT COUNT(*) as count FROM example_sentences es
          INNER JOIN vocabulary v ON v.id = es.vocab_id AND v.jlpt_level = ?
          WHERE es.audit_status = 'verified'
        ''', [jlpt]);
        if (sentenceTotal.isNotEmpty) {
          displayTotal = (sentenceTotal.first['count'] as num?)?.toInt() ?? 0;
        }

        final sentenceStudied = await db.rawQuery('''
          SELECT COUNT(*) as count FROM example_sentences es
          INNER JOIN vocabulary v ON v.id = es.vocab_id AND v.jlpt_level = ?
          WHERE es.audit_status = 'verified'
          AND es.vocab_id IN (SELECT vocab_id FROM $progressTable)
        ''', [jlpt]);
        if (sentenceStudied.isNotEmpty) {
          displayStudied = (sentenceStudied.first['count'] as num?)?.toInt() ?? 0;
        }
      }

      return {
        'new': displayNew,
        'vault_remaining': remainingNew,
        'learn': learnC,
        'due': dueC,
        'total': displayTotal,
        'studied': displayStudied
      };
    } catch (e, stack) {
      print("DATABASE_HELPER_ERROR: getSRSStats failed: $e");
      print(stack);
      return {'new': 0, 'vault_remaining': 0, 'learn': 0, 'due': 0, 'total': 0, 'studied': 0};
    }
  }

  Future<List<Map<String, dynamic>>> getGrammarCards() async {
    final db = await database;
    final grammarLv = _grammarTag();
    return await db.rawQuery('''
      SELECT c.* FROM grammar_cards c
      INNER JOIN grammar_rules r ON c.grammar_id = r.id
      WHERE c.audit_status = ? AND r.grammar_level = ?
      LIMIT 20
    ''', ['verified', grammarLv]);
  }

  Future<List<Map<String, dynamic>>> getVocabulary() async {
    final db = await database;
    final jlpt = _activeLevel;
    if (jlpt == null) return [];
    return await db.query(
      'vocabulary',
      where: 'jlpt_level = ?',
      whereArgs: [jlpt],
      limit: 20,
    );
  }

  Future<List<Map<String, dynamic>>> getExampleSentences(int vocabId) async {
    final db = await database;
    return await db.query(
      'example_sentences',
      where: "vocab_id = ? AND audit_status = ?",
      whereArgs: [vocabId, 'verified'],
    );
  }

  Future<List<Map<String, dynamic>>> getStudySessionCards(bool isVocab) async {
    final db = await database;
    final progressTable = isVocab ? 'user_vocabulary_progress' : 'user_grammar_progress';
    final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';
    final idColumn = isVocab ? 'vocab_id' : 'grammar_id';
    final jlpt = _activeLevel;
    final grammarLv = _grammarTag();

    final prefs = await SharedPreferences.getInstance();
    int dailyLimit = prefs.getInt('daily_new_card_limit') ?? 20;
    String studiedKey =
        isVocab ? 'vocab_new_cards_studied_today' : 'grammar_new_cards_studied_today';
    int studiedToday = prefs.getInt(studiedKey) ?? 0;
    int allowedNewCards = dailyLimit - studiedToday;
    if (allowedNewCards < 0) allowedNewCards = 0;

    final grammarLevelJoin = !isVocab
        ? 'INNER JOIN grammar_rules r ON c.grammar_id = r.id AND r.grammar_level = ?'
        : '';

    final List<Map<String, dynamic>> learningCards;
    final List<Map<String, dynamic>> reviewCards;

    if (isVocab && jlpt != null) {
      learningCards = await db.rawQuery('''
      SELECT c.*, 
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      WHERE (p.state = 'learning' OR p.state = 'relearning')
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND c.jlpt_level = ?
      ORDER BY p.next_review_at ASC
    ''', [jlpt]);

      reviewCards = await db.rawQuery('''
      SELECT c.*,
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      WHERE p.state = 'review'
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND c.jlpt_level = ?
      ORDER BY p.next_review_at ASC
    ''', [jlpt]);
    } else if (!isVocab) {
      learningCards = await db.rawQuery('''
      SELECT c.*, 
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at,
             r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      $grammarLevelJoin
      WHERE (p.state = 'learning' OR p.state = 'relearning')
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND c.audit_status = 'verified'
      ORDER BY p.next_review_at ASC
    ''', [grammarLv]);

      reviewCards = await db.rawQuery('''
      SELECT c.*,
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at,
             r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      $grammarLevelJoin
      WHERE p.state = 'review'
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND c.audit_status = 'verified'
      ORDER BY p.next_review_at ASC
    ''', [grammarLv]);
    } else {
      learningCards = [];
      reviewCards = [];
    }

    List<Map<String, dynamic>> newCards = [];
    if (allowedNewCards > 0) {
      newCards = await getNewCards(isVocab, limit: allowedNewCards);
    }

    return [...learningCards, ...reviewCards, ...newCards];
  }

  Future<List<Map<String, dynamic>>> getNewCards(bool isVocab, {int limit = 10}) async {
    final db = await database;
    final progressTable = isVocab ? 'user_vocabulary_progress' : 'user_grammar_progress';
    final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';
    final idColumn = isVocab ? 'vocab_id' : 'grammar_id';
    final jlpt = _activeLevel;
    final grammarLv = _grammarTag();

    if (isVocab && jlpt != null) {
      final randomCategoryResult = await db.rawQuery('''
        SELECT category FROM $contentTable 
        WHERE jlpt_level = ? AND id NOT IN (SELECT $idColumn FROM $progressTable) 
        ORDER BY RANDOM() LIMIT 1
      ''', [jlpt]);

      if (randomCategoryResult.isNotEmpty) {
        final targetCategory = randomCategoryResult.first['category'] as String?;
        return await db.rawQuery('''
          SELECT * FROM $contentTable 
          WHERE jlpt_level = ? AND id NOT IN (SELECT $idColumn FROM $progressTable) 
          ORDER BY CASE WHEN category = ? THEN 0 ELSE 1 END, category ASC, id ASC
          LIMIT ?
        ''', [jlpt, targetCategory, limit]);
      }
    }

    if (!isVocab) {
      return await db.rawQuery('''
      SELECT c.*, r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure 
      FROM $contentTable c
      INNER JOIN grammar_rules r ON c.grammar_id = r.id AND r.grammar_level = ?
      WHERE c.id NOT IN (SELECT $idColumn FROM $progressTable) 
      AND c.audit_status = 'verified'
      ORDER BY c.grammar_id ASC, c.id ASC
      LIMIT ?
    ''', [grammarLv, limit]);
    }

    if (jlpt == null) return [];

    return await db.rawQuery('''
      SELECT * FROM $contentTable 
      WHERE jlpt_level = ? AND id NOT IN (SELECT $idColumn FROM $progressTable) 
      ORDER BY category ASC, id ASC
      LIMIT ?
    ''', [jlpt, limit]);
  }

  Map<String, String> getSRSIntervals(Map<String, dynamic>? progress) {
    if (progress == null ||
        (progress['state'] ?? 'new') == 'new' ||
        progress['state'] == 'learning' ||
        progress['state'] == 'relearning') {
      int reps = (progress?['repetition_count'] as int?) ?? 0;
      return {
        'again': '1m',
        'hard': reps == 0 ? '6m' : '10m',
        'good': reps == 0 ? '10m' : '1d',
        'easy': '4d',
      };
    } else {
      double ease = (progress['ease_factor'] as num?)?.toDouble() ?? 2.5;
      int interval = (progress['interval_days'] as int?) ?? 1;

      return {
        'again': '1m',
        'hard': '${(interval * 1.2).ceil()}d',
        'good': '${(interval * ease).ceil()}d',
        'easy': '${(interval * ease * 1.3).ceil()}d',
      };
    }
  }

  Future<void> updateSRSProgress(bool isVocab, int id, String rating) async {
    final db = await database;
    final progressTable = isVocab ? 'user_vocabulary_progress' : 'user_grammar_progress';
    final idColumn = isVocab ? 'vocab_id' : 'grammar_id';

    final List<Map<String, dynamic>> progressRecords = await db.query(
      progressTable,
      where: '$idColumn = ?',
      whereArgs: [id],
    );

    int interval = 0;
    double easeFactor = 2.5;
    int repetitions = 0;
    int lapses = 0;
    String state = 'new';

    if (progressRecords.isNotEmpty) {
      final p = progressRecords.first;
      interval = (p['interval_days'] as int?) ?? 0;
      easeFactor = (p['ease_factor'] as num?)?.toDouble() ?? 2.5;
      repetitions = (p['repetition_count'] as int?) ?? 0;
      lapses = (p['lapses'] as int?) ?? 0;
      state = (p['state'] as String?) ?? 'learning';
    }

    DateTime now = DateTime.now().toUtc();
    DateTime nextReview = now;

    print("SRS_DEBUG: ID=$id Rating=$rating CurrentReps=$repetitions State=$state");
    if (state == 'new' || state == 'learning' || state == 'relearning') {
      switch (rating.toLowerCase()) {
        case 'again':
          nextReview = now.add(const Duration(minutes: 1));
          state = 'learning';
          repetitions = 0;
          break;
        case 'hard':
          if (repetitions == 0) {
            nextReview = now.add(const Duration(minutes: 6));
          } else {
            nextReview = now.add(const Duration(minutes: 10));
          }
          state = 'learning';
          break;
        case 'good':
          if (repetitions == 0) {
            nextReview = now.add(const Duration(minutes: 10));
            repetitions = 1;
            state = 'learning';
          } else {
            nextReview = now.add(const Duration(days: 1));
            interval = 1;
            state = 'review';
          }
          break;
        case 'easy':
          nextReview = now.add(const Duration(days: 4));
          interval = 4;
          state = 'review';
          break;
      }
    } else {
      switch (rating.toLowerCase()) {
        case 'again':
          interval = 1;
          easeFactor = (easeFactor - 0.20).clamp(1.3, 5.0);
          lapses++;
          state = 'relearning';
          repetitions = 0;
          nextReview = now.add(const Duration(minutes: 1));
          break;
        case 'hard':
          interval = (interval * 1.2).ceil();
          easeFactor = (easeFactor - 0.15).clamp(1.3, 5.0);
          nextReview = now.add(Duration(days: interval));
          break;
        case 'good':
          interval = (interval * easeFactor).ceil();
          nextReview = now.add(Duration(days: interval));
          break;
        case 'easy':
          interval = (interval * easeFactor * 1.3).ceil();
          easeFactor = (easeFactor + 0.15).clamp(1.3, 5.0);
          nextReview = now.add(Duration(days: interval));
          break;
      }
    }

    String formatSqlite(DateTime dt) {
      return dt.toIso8601String().replaceAll('T', ' ').substring(0, 19);
    }

    print("SRS_DEBUG: NEXT STATE=$state REPS=$repetitions NEXT_REVIEW=${formatSqlite(nextReview)}");

    await db.insert(
      progressTable,
      {
        idColumn: id,
        'state': state,
        'interval_days': interval,
        'ease_factor': easeFactor,
        'repetition_count': repetitions,
        'lapses': lapses,
        'last_reviewed_at': formatSqlite(now),
        'next_review_at': formatSqlite(nextReview),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> resetProgress() async {
    final db = await database;
    await db.delete('user_vocabulary_progress');
    await db.delete('user_grammar_progress');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('vocab_new_cards_studied_today', 0);
    await prefs.setInt('grammar_new_cards_studied_today', 0);
    await prefs.setString('last_study_date', DateTime.now().toIso8601String().split('T')[0]);
  }
}
