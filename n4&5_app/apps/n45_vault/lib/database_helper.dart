import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, 'n45_vault.db');

      // Check if the database exists
      final exists = await databaseExists(path);

      if (!exists) {
        await _copyFromAssets(path);
      } else {
        print("DATABASE_HELPER: Opening existing database at $path");
      }

      var db = await openDatabase(path);

      // Check for core tables to ensure asset sync (if grammar_cards is missing, the DB is stale)
      final tableCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='grammar_cards'",
      );
      if (tableCheck.isEmpty) {
        print(
          "DATABASE_HELPER: Core tables missing (grammar_cards), forcing re-copy from assets...",
        );
        await db.close();
        await _copyFromAssets(path);
        db = await openDatabase(path);
      }

      print("DATABASE_HELPER: Database opened successfully");

      // Ensure progress tables exist for existing databases
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

  Future<void> _copyFromAssets(String path) async {
    print("DATABASE_HELPER: Copying database from assets to $path");
    try {
      await Directory(dirname(path)).create(recursive: true);
      ByteData data = await rootBundle.load(join('assets', 'n45_vault.db'));
      List<int> bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await File(path).writeAsBytes(bytes, flush: true);
      print("DATABASE_HELPER: Copy successful");
    } catch (e) {
      print("DATABASE_HELPER_ERROR: Copy from assets failed: $e");
      rethrow;
    }
  }

  Future<void> refreshDatabase() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, 'n45_vault.db');

      if (_database != null) {
        await _database!.close();
        _database = null;
      }

      await _copyFromAssets(path);
      _database = await openDatabase(path);
      print("DATABASE_HELPER: Database refreshed successfully");
    } catch (e) {
      print("DATABASE_HELPER_ERROR: Refresh failed: $e");
      rethrow;
    }
  }

  /// Get SRS Stats: New, Learn, Due, Total
  Future<Map<String, int>> getSRSStats(bool isVocab) async {
    print("DATABASE_HELPER: getSRSStats started (isVocab: $isVocab)");
    try {
      final db = await database;
      final progressTable = isVocab
          ? 'user_vocabulary_progress'
          : 'user_grammar_progress';
      final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';

      final statusCounts = await db.rawQuery('''
        SELECT 
          SUM(CASE WHEN (state = 'learning' OR state = 'relearning') AND next_review_at <= CURRENT_TIMESTAMP THEN 1 ELSE 0 END) as learn_count,
          SUM(CASE WHEN state = 'review' AND next_review_at <= CURRENT_TIMESTAMP THEN 1 ELSE 0 END) as due_count
        FROM $progressTable
      ''');

      int learnC = 0, dueC = 0;
      if (statusCounts.isNotEmpty) {
        learnC = (statusCounts.first['learn_count'] as num?)?.toInt() ?? 0;
        dueC = (statusCounts.first['due_count'] as num?)?.toInt() ?? 0;
      }

      final prefs = await SharedPreferences.getInstance();
      final includeN4 = prefs.getBool('include_n4_cards') ?? true;
      final includeN5 = prefs.getBool('include_n5_cards') ?? true;
      final vocabLevelClause = includeN4 && includeN5
          ? "1=1"
          : (includeN4
                ? "jlpt_level = 4"
                : (includeN5 ? "jlpt_level = 5" : "1=0"));
      final grammarLevelClause = includeN4 && includeN5
          ? "1=1"
          : (includeN4
                ? "r.grammar_level = 'N4'"
                : (includeN5 ? "r.grammar_level = 'N5'" : "1=0"));

      int totalVault = 0;
      final totalRecords = await db.rawQuery(
        isVocab
            ? "SELECT COUNT(*) as count FROM $contentTable WHERE $vocabLevelClause"
            : "SELECT COUNT(*) as count FROM $contentTable c LEFT JOIN grammar_rules r ON c.grammar_id = r.id WHERE c.audit_status = 'verified' AND $grammarLevelClause",
      );
      if (totalRecords.isNotEmpty) {
        totalVault = (totalRecords.first['count'] as num?)?.toInt() ?? 0;
      }

      int studied = 0;
      final studiedRecords = await db.rawQuery(
        isVocab
            ? "SELECT COUNT(*) as count FROM $progressTable p JOIN vocabulary v ON p.vocab_id = v.id WHERE $vocabLevelClause"
            : "SELECT COUNT(*) as count FROM $progressTable p JOIN grammar_cards c ON p.grammar_id = c.id LEFT JOIN grammar_rules r ON c.grammar_id = r.id WHERE c.audit_status = 'verified' AND $grammarLevelClause",
      );
      if (studiedRecords.isNotEmpty) {
        studied = (studiedRecords.first['count'] as num?)?.toInt() ?? 0;
      }

      int remainingNew = totalVault - studied;

      int dailyLimit = prefs.getInt('daily_new_card_limit') ?? 20;
      String studiedKey = isVocab
          ? 'vocab_new_cards_studied_today'
          : 'grammar_new_cards_studied_today';
      int studiedToday = prefs.getInt(studiedKey) ?? 0;
      int allowedNewCards = dailyLimit - studiedToday;
      if (allowedNewCards < 0) allowedNewCards = 0;

      int displayNew = allowedNewCards > remainingNew
          ? remainingNew
          : allowedNewCards;

      // User Request: Make the progress mountain substantial by tracking Sentences
      int displayTotal = totalVault;
      int displayStudied = studied;

      if (isVocab) {
        final sentenceTotal = await db.rawQuery(
          "SELECT COUNT(*) as count FROM example_sentences s JOIN vocabulary v ON s.vocab_id = v.id WHERE s.audit_status = 'verified' AND $vocabLevelClause",
        );
        if (sentenceTotal.isNotEmpty) {
          displayTotal = (sentenceTotal.first['count'] as num?)?.toInt() ?? 0;
        }

        final sentenceStudied = await db.rawQuery(
          "SELECT COUNT(*) as count FROM example_sentences s JOIN vocabulary v ON s.vocab_id = v.id WHERE s.audit_status = 'verified' AND $vocabLevelClause AND s.vocab_id IN (SELECT vocab_id FROM $progressTable)",
        );
        if (sentenceStudied.isNotEmpty) {
          displayStudied =
              (sentenceStudied.first['count'] as num?)?.toInt() ?? 0;
        }
      }

      return {
        'new': displayNew,
        'vault_remaining': remainingNew,
        'learn': learnC,
        'due': dueC,
        'total': displayTotal,
        'studied': displayStudied,
      };
    } catch (e, stack) {
      print("DATABASE_HELPER_ERROR: getSRSStats failed: $e");
      print(stack);
      return {
        'new': 0,
        'vault_remaining': 0,
        'learn': 0,
        'due': 0,
        'total': 0,
        'studied': 0,
      };
    }
  }

  /// Query Grammar cards
  Future<List<Map<String, dynamic>>> getGrammarCards() async {
    final db = await database;
    return await db.query(
      'grammar_cards',
      where: "audit_status = ?",
      whereArgs: ['verified'],
      limit: 20,
    );
  }

  /// Query Vocabulary
  Future<List<Map<String, dynamic>>> getVocabulary() async {
    final db = await database;
    return await db.query('vocabulary', limit: 20);
  }

  /// Query Example Sentences for a specific vocab entry
  Future<List<Map<String, dynamic>>> getExampleSentences(int vocabId) async {
    final db = await database;
    return await db.query(
      'example_sentences',
      where: "vocab_id = ? AND audit_status = ?",
      whereArgs: [vocabId, 'verified'],
    );
  }

  /// Fetch cards for a session (Reviews + New)
  Future<List<Map<String, dynamic>>> getStudySessionCards(bool isVocab) async {
    final db = await database;
    final progressTable = isVocab
        ? 'user_vocabulary_progress'
        : 'user_grammar_progress';
    final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';
    final idColumn = isVocab ? 'vocab_id' : 'grammar_id';

    final prefs = await SharedPreferences.getInstance();
    int dailyLimit = prefs.getInt('daily_new_card_limit') ?? 20;
    final includeN4 = prefs.getBool('include_n4_cards') ?? true;
    final includeN5 = prefs.getBool('include_n5_cards') ?? true;
    final vocabLevelClause = includeN4 && includeN5
        ? "1=1"
        : (includeN4
              ? "c.jlpt_level = 4"
              : (includeN5 ? "c.jlpt_level = 5" : "1=0"));
    final grammarLevelClause = includeN4 && includeN5
        ? "1=1"
        : (includeN4
              ? "r.grammar_level = 'N4'"
              : (includeN5 ? "r.grammar_level = 'N5'" : "1=0"));
    final levelFilterClause = isVocab ? vocabLevelClause : grammarLevelClause;
    String studiedKey = isVocab
        ? 'vocab_new_cards_studied_today'
        : 'grammar_new_cards_studied_today';
    int studiedToday = prefs.getInt(studiedKey) ?? 0;
    int allowedNewCards = dailyLimit - studiedToday;
    if (allowedNewCards < 0) allowedNewCards = 0;

    // Priority 1: Learning Cards (Due Now) -> No limit
    final List<Map<String, dynamic>> learningCards = await db.rawQuery('''
      SELECT c.*, 
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at
             ${!isVocab ? ", r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure" : ""}
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      ${!isVocab ? "LEFT JOIN grammar_rules r ON c.grammar_id = r.id" : ""}
      WHERE (p.state = 'learning' OR p.state = 'relearning')
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND ${isVocab ? "1=1" : "c.audit_status = 'verified'"}
      AND $levelFilterClause
      ORDER BY p.next_review_at ASC
    ''');

    // Priority 2: Review Cards (Due Today) -> No limit
    final List<Map<String, dynamic>> reviewCards = await db.rawQuery('''
      SELECT c.*,
             p.state, p.interval_days, p.ease_factor, p.repetition_count, p.lapses, p.last_reviewed_at, p.next_review_at
             ${!isVocab ? ", r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure" : ""}
      FROM $contentTable c
      INNER JOIN $progressTable p ON c.id = p.$idColumn
      ${!isVocab ? "LEFT JOIN grammar_rules r ON c.grammar_id = r.id" : ""}
      WHERE p.state = 'review'
      AND p.next_review_at <= CURRENT_TIMESTAMP
      AND ${isVocab ? "1=1" : "c.audit_status = 'verified'"}
      AND $levelFilterClause
      ORDER BY p.next_review_at ASC
    ''');

    // Priority 3: New Cards (Capped to allowedNewCards)
    List<Map<String, dynamic>> newCards = [];
    if (allowedNewCards > 0) {
      newCards = await getNewCards(isVocab, limit: allowedNewCards);
    }

    return [...learningCards, ...reviewCards, ...newCards];
  }

  /// Cold Start: Fetch cards not yet in the progress table
  Future<List<Map<String, dynamic>>> getNewCards(
    bool isVocab, {
    int limit = 10,
  }) async {
    final db = await database;
    final progressTable = isVocab
        ? 'user_vocabulary_progress'
        : 'user_grammar_progress';
    final contentTable = isVocab ? 'vocabulary' : 'grammar_cards';
    final idColumn = isVocab ? 'vocab_id' : 'grammar_id';
    final prefs = await SharedPreferences.getInstance();
    final includeN4 = prefs.getBool('include_n4_cards') ?? true;
    final includeN5 = prefs.getBool('include_n5_cards') ?? true;
    final vocabLevelClause = includeN4 && includeN5
        ? "1=1"
        : (includeN4
              ? "jlpt_level = 4"
              : (includeN5 ? "jlpt_level = 5" : "1=0"));
    final vocabLevelClauseAliased = includeN4 && includeN5
        ? "1=1"
        : (includeN4
              ? "c.jlpt_level = 4"
              : (includeN5 ? "c.jlpt_level = 5" : "1=0"));
    final grammarLevelClauseAliased = includeN4 && includeN5
        ? "1=1"
        : (includeN4
              ? "r.grammar_level = 'N4'"
              : (includeN5 ? "r.grammar_level = 'N5'" : "1=0"));

    if (isVocab) {
      // 1. Find a random category that has unstudied cards
      final randomCategoryResult = await db.rawQuery('''
        SELECT category FROM $contentTable 
        WHERE id NOT IN (SELECT $idColumn FROM $progressTable) 
        AND $vocabLevelClause
        ORDER BY RANDOM() LIMIT 1
      ''');

      if (randomCategoryResult.isNotEmpty) {
        final targetCategory =
            randomCategoryResult.first['category'] as String?;
        return await db.rawQuery(
          '''
          SELECT * FROM $contentTable 
          WHERE id NOT IN (SELECT $idColumn FROM $progressTable) 
          AND $vocabLevelClause
          ORDER BY CASE WHEN category = ? THEN 0 ELSE 1 END, category ASC, id ASC
          LIMIT ?
        ''',
          [targetCategory, limit],
        );
      }
    }

    // Fallback for grammar or if no new vocab category is found
    return await db.rawQuery(
      '''
      SELECT c.*${!isVocab ? ", r.name as grammar_name, r.meaning as grammar_meaning, r.structure as rule_structure" : ""} 
      FROM $contentTable c
      ${!isVocab ? "LEFT JOIN grammar_rules r ON c.grammar_id = r.id" : ""}
      WHERE c.id NOT IN (SELECT $idColumn FROM $progressTable) 
      AND ${isVocab ? "1=1" : "c.audit_status = 'verified'"}
      AND ${isVocab ? vocabLevelClauseAliased : grammarLevelClauseAliased}
      ORDER BY ${isVocab ? "c.category ASC, c.id ASC" : "c.grammar_id ASC, c.id ASC"}
      LIMIT ?
    ''',
      [limit],
    );
  }

  /// Get predicted intervals for UI display
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

  /// Update SRS Progress using Anki-standard & SM-2 Algorithm
  Future<void> updateSRSProgress(bool isVocab, int id, String rating) async {
    final db = await database;
    final progressTable = isVocab
        ? 'user_vocabulary_progress'
        : 'user_grammar_progress';
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

    print(
      "SRS_DEBUG: ID=$id Rating=$rating CurrentReps=$repetitions State=$state",
    );
    if (state == 'new' || state == 'learning' || state == 'relearning') {
      // LEARNING PHASE (Steps: 1m, 10m)
      switch (rating.toLowerCase()) {
        case 'again':
          nextReview = now.add(const Duration(minutes: 1));
          state = 'learning';
          repetitions = 0;
          break;
        case 'hard':
          if (repetitions == 0) {
            nextReview = now.add(
              const Duration(minutes: 6),
            ); // Average of 1m and 10m
          } else {
            nextReview = now.add(
              const Duration(minutes: 10),
            ); // Repeat the 10m step
          }
          state = 'learning';
          break;
        case 'good':
          if (repetitions == 0) {
            nextReview = now.add(const Duration(minutes: 10));
            repetitions = 1;
            state = 'learning';
          } else {
            nextReview = now.add(const Duration(days: 1)); // Graduate
            interval = 1;
            state = 'review';
          }
          break;
        case 'easy':
          nextReview = now.add(
            const Duration(days: 4),
          ); // Immediate Graduation (Easy)
          interval = 4;
          state = 'review';
          break;
      }
    } else {
      // REVIEW PHASE (SM-2)
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

    // Format exactly as SQLite CURRENT_TIMESTAMP (YYYY-MM-DD HH:MM:SS)
    // to ensure `< CURRENT_TIMESTAMP` logic evaluates safely without 'T' > ' ' collisions
    String formatSqlite(DateTime dt) {
      return dt.toIso8601String().replaceAll('T', ' ').substring(0, 19);
    }

    print(
      "SRS_DEBUG: NEXT STATE=$state REPS=$repetitions NEXT_REVIEW=${formatSqlite(nextReview)}",
    );

    await db.insert(progressTable, {
      idColumn: id,
      'state': state,
      'interval_days': interval,
      'ease_factor': easeFactor,
      'repetition_count': repetitions,
      'lapses': lapses,
      'last_reviewed_at': formatSqlite(now),
      'next_review_at': formatSqlite(nextReview),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Reset all study progress
  Future<void> resetProgress() async {
    final db = await database;
    await db.delete('user_vocabulary_progress');
    await db.delete('user_grammar_progress');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('vocab_new_cards_studied_today', 0);
    await prefs.setInt('grammar_new_cards_studied_today', 0);
    await prefs.setString(
      'last_study_date',
      DateTime.now().toIso8601String().split('T')[0],
    );
  }
}
