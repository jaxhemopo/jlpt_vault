# JLPT Vault — vocabulary card & example-sentence rules

Canonical reference for **human editors**, **audit agents**, and **Cursor Automations**
that touch bundled SQLite assets (`vault_n45.db`, `vault_n3.db`, `vault_n2.db`, `vault_n1.db`).

Derived from app code (`study_arena.dart`, `database_helper.dart`) and audit conventions
(`audit/report_*.md`, `audit/review_fixes_*.md`).

---

## 1. Scope

These rules apply to:

| Table | What |
|-------|------|
| `vocabulary` | Headword row (`id`, `kanji`, `reading`, `english_meaning`, `jlpt_level`, `category`) |
| `example_sentences` | Two example rows per vocab card (`vocab_id`, `sentence_jp`, `sentence_en`, `audit_status`) |

Grammar cards (`grammar_cards`, `grammar_rules`) have separate rules; this document is **vocab-only**.

---

## 2. How the app uses a sentence (must-parse correctly)

### 2.1 Only `verified` sentences are shown

```dart
// database_helper.dart — getExampleSentences()
where: "vocab_id = ? AND audit_status = ?"
whereArgs: [vocabId, 'verified']
```

Any sentence with `audit_status` other than `verified` is **invisible** in study mode.
After edits, set `audit_status = 'verified'`.

### 2.2 Furigana / reading annotation format

The renderer (`FuriganaText` in `study_arena.dart`) recognizes **only**:

```
漢字[かな]
Word(かな)
```

Regex (ASCII brackets/parens only):

```
([^ \s\[\(\n\r]+)[\[\(]([^\]\)]+)[\]\)]
```

**Must**

- Use **half-width** `[` `]` or `(` `)` — **not** full-width `（）`.
- Bracket content is **kana only** (hiragana/katakana). Never `かな[漢字]` (reversed).
- Brackets must be **balanced**.

**Accepted deck conventions** (do not “fix” unless wrong reading):

- Okurigana inside brackets: `投[な]げる`, `嘆[な]げく`, `捧[ささ]げる`
- Whole-word bracket: `抗議[こうぎ]する`
- Redundant kana-on-kana: `こたつ[こたつ]` (harmless)
- Katakana loanword with optional gloss: `コーナー[こーなー]`

**TTS** strips all `[…]` and `(…)` before speaking — bracketed text is display-only.

### 2.3 Target-word highlighting (study card front)

On the **front** of a vocab card, the example sentence hides furigana for the **target word**
and bold-highlights it. Target is taken from the vocab row:

```dart
target: card['kanji'] ?? card['reading']   // front
target: card['kanji']                       // back
```

Matching logic:

1. **Exact match** — builds a regex from each character of `kanji`/`reading`, allowing optional
   `[furigana]` after each character.
2. **Fallback** — any kanji character from the headword that appears in the sentence is highlighted
   (helps conjugated forms).

Implications:

- If the sentence uses a **different kanji** or **different reading** than the card teaches,
  the student sees the wrong word highlighted (or poor cloze behavior).
- If the sentence uses only **kana** for a kanji headword with no matching kanji in the sentence
  (e.g. card `書く` but sentence only has `かきます` with no `書`), highlighting is weak.

### 2.4 Example rotation

Vocab study loads **all** `verified` sentences for a card and rotates:

```dart
index = repetition_count % examples.length
```

**Every card must have exactly 2 verified sentences** (unless explicitly exempted).

### 2.5 `cloze_deletion_index`

Column exists on `example_sentences` but **vocab study does not use it** today.
Leave as `0` when editing vocab sentences. Do not rely on it for vocab QA.

---

## 3. Audit order (always follow this sequence)

**Validate the vocabulary row first, then its sentences.**

If `kanji`, `reading`, and `english_meaning` on the card disagree with each other, sentence
checks are misleading — you may “fix” sentences to match a broken headword. Fix or flag the
card row before touching `example_sentences`.

```
1. vocabulary row  (kanji ↔ reading ↔ english_meaning)
2. example_sentences  (both rows vs that vocab_id)
3. furigana / parse / English polish
```

---

## 4. Rule 0 — Vocab card row must be internally consistent (highest priority)

Each `vocabulary` row is the **source of truth** for what is being taught. All three headword
fields must describe the **same word, same reading, same sense**.

| Field | Role |
|-------|------|
| `kanji` | Written form shown on the card (may be kana-only, compound, or pattern like `～だす`) |
| `reading` | The reading taught for that form (hiragana/katakana; may list variants with `;`) |
| `english_meaning` | The sense taught — must match that kanji+reading pair, not a homograph |

### 4.1 What “match” means

- **Kanji ↔ reading:** The reading is a valid, standard reading for the kanji/spelling shown —
  not a different word that happens to look similar.
- **Kanji ↔ english_meaning:** The gloss describes what **this** kanji+reading means, not a
  different sense of the same character or a different word entirely.
- **Reading ↔ english_meaning:** The gloss fits the reading (e.g. don’t gloss めし as “rice
  (polite)” if the reading is めし not ごはん).

### 4.2 Common card-row failures (flag or fix before sentences)

| Problem | Example | Action |
|---------|---------|--------|
| Wrong kanji for reading | `kanji=副`, `reading=とりわけ` | Change to `取り分け` or kana `とりわけ` |
| Wrong reading for kanji | `kanji=数`, `reading=すう` but card teaches standalone かず | Align reading to taught sense |
| Grammar tag in fields | `kanji=ごらんなさい (かん)` | Strip `(かん)` from kanji and reading |
| POS / note in reading | `reading=よし (かん)`, `reading=はい (かん)` | Remove tag; keep lemma only |
| English is a different sense | `kanji=光`, reading `～こう`, EN “light, sunshine” | EN should match suffix/compound sense taught |
| English is a different word | `kanji=額`, reading `がく`, EN describes 額縁 only but reading is frame sense — OK; EN “forehead” when sentences use がく frame — **bad** | Align EN to taught sense |
| Homograph collision | Two entries for same surface, wrong id linked | Split/fix rows; don’t patch via sentences |
| Duplicate lemma | Two ids for same kanji+reading | Merge; delete duplicate; re-link sentences |
| Kana/kanji mismatch | `kanji=ひどい`, `reading=ひどい` but display expects kanji 酷い | Optional: add kanji if standard |
| Pattern card missing pattern marker | `kanji=続ける`, `reading=～続ける` | Keep `～` in kanji; reading documents pattern |

Real audit examples (from `review_fixes_n*.md` / `report_*.md`):

- **392 副 / とりわけ** — kanji 副 does not read とりわけ; should be 取り分け.
- **254 正** — reading せい vs sentences using ただしい → card aligned to 正しい sense.
- **182 印** — reading しるし vs sentences using いん (seal) → reading fixed to いん.
- **131 ごらんなさい (かん)** — `(かん)` leaked from POS tag into kanji/reading fields.
- **259 決 / けつ** — noun 決 (vote) vs sentences demonstrating verb 決める/決する.

### 4.3 Multi-reading and pattern cards

- **`reading` with `;`** — each variant must be a valid alternative for the same headword
  (e.g. `いく; ゆく`). English should cover the shared sense or note the distinction briefly.
- **`(する)` in kanji** — e.g. `相談 (する)` / `相談する`: reading is the noun+する form;
  english_meaning should describe the verbalized usage.
- **`～` prefix/suffix** — kanji field carries the pattern; reading is the bound form
  (e.g. `～だす`, `～やすい`). English describes the pattern, not a unrelated lemma.

### 4.4 When card row is wrong — fix order

1. **Fix `kanji` / `reading` / `english_meaning`** on the vocabulary row (or split into a
   new card if it’s a homograph).
2. **Then** rewrite sentences so they use the corrected headword.
3. Never only rewrite sentences to match a wrong card — that hides the bug.

### 4.5 Automated card-row checks (minimum)

For every `vocabulary` row, flag when:

- `kanji` or `reading` contains `(`, `)`, `（`, `）`, or obvious POS tags: `(かん)`, `(する)`
  is OK in kanji **only** when consistently part of deck convention — otherwise strip.
- `kanji` is a single kanji but `reading` clearly belongs to another lexeme (heuristic:
  another row in the same DB uses that kanji with the reading on the card).
- `english_meaning` contains raw Japanese / kana glosses (same lint as sentences).
- Same `(kanji, reading)` pair appears on **two ids** (duplicate lemma).
- **Sentences consistently use a different reading** than the card (card–sentence drift) —
  treat as **card row suspect first**, then fix sentences after card is confirmed.

Full kanji→reading validation ideally uses a dictionary table (`audit/jlpt_reading_map.json`
or JMdict slice) — see §13.

---

## 5. Rule A — Sentences must match their vocab_id (second priority)

For `example_sentences.vocab_id = N`, both sentences must teach the **same lexeme** as
`vocabulary` row `N` **after Rule 0 passes**: same **kanji form** and same **reading** as
stored on the card.

### 5.1 Correct vs incorrect

| Card (`vocab_id`) | ✅ Good | ❌ Bad |
|-------------------|---------|--------|
| 飯 / めし | 飯[めし]を食[た]べる | ご飯[ごはん]を… (different lemma/reading) |
| 購入 / こうにゅう | 本[ほん]を購入[こうにゅう]する | 購買[こうばい] (different word) |
| 届 / とどけ (noun) | 欠席[けっせき]届[とどけ]を出[だ]す | 届[とど]ける (verb; different entry) |
| 取り分け / とりわけ | 取[と]り分[わ]けが… | 副[とりわけ] (wrong kanji for reading) |

### 5.2 Conjugation is allowed

The surface form may conjugate; the **reading of the target morpheme** must still match the card:

- 投[な]げる → 投[な]げました ✅
- びっくりする → びっくりしました ✅
- いじめる → いじめられている ✅ (same lexeme)

### 5.3 Same kanji, different reading

If common usage reads the kanji differently than the card (e.g. card teaches 光 / こう as suffix
but sentence uses 光 / ひかり), **rewrite the sentence** or **fix the card (Rule 0)** — do not leave mismatched.

### 5.4 Kana / katakana headwords

- Hiragana card `びら` may appear as katakana `ビラ` in text ✅
- Katakana card `ビル` stays unbracketed ✅
- Do not substitute a synonym loanword (e.g. チラシ for ビラ) unless the card teaches that form.

### 5.5 Pattern / suffix / prefix cards

| Card type | Sentence must demonstrate |
|-----------|---------------------------|
| `～やすい` | adjective stem + やすい |
| `～だす` | verb stem + だす / だした |
| `～君` | name + 君[くん] |
| `～時` | time + 時[じ] (e.g. 三時[さんじ]) |
| `(する)` nouns | 相談[そうだん]する, 食事[しょくじ]する |
| `御～` / `お～` | ご家族, お名前, etc. |

### 5.6 Automated check (minimum)

For each sentence, verify at least one of:

- Card `kanji` (minus grammar tags like `(する)`) appears in `sentence_jp`, or
- Card `reading` (or its verb stem) appears in plain text or inside `[brackets]`, or
- For suffix/prefix cards, the bound pattern appears as described above.

**Fail → rewrite sentence** (or fix card first if Rule 0 failure caused the drift).

---

## 6. Rule B — Furigana by deck level (reader support)

`vocabulary.jlpt_level` on the bundled DB defines the **deck level** (5=N5 … 1=N1).
N4/N5 share `vault_n45.db` but rows still have `jlpt_level` 4 or 5.

### 6.1 Principle

Students are assumed to know kanji **at or below** their deck level without extra help.
Kanji **above** deck level appearing incidentally in a sentence need `[reading]` so the app
can show furigana when the user toggles it on.

### 6.2 Furigana required

In a **level L** database, any **incidental** kanji whose JLPT level is **strictly higher than L**
(i.e. more advanced: N1=hardest … N5=easiest) must have `漢字[よみ]` annotation.

| Deck DB | Levels that need brackets on incidental kanji |
|---------|-----------------------------------------------|
| `vault_n45` (N4/N5) | N3, N2, N1 kanji |
| `vault_n3` | N2, N1 kanji |
| `vault_n2` | N1 kanji |
| `vault_n1` | (none above N1) |

**Target headword kanji** should always be annotated when it contains kanji, regardless of level
(so the app can hide/show the taught reading on the card front).

### 6.3 Furigana optional (leave as-is if present)

- Kanji at or **below** deck level (N4/N5 kanji in N3 deck, etc.).
- Already-correct brackets on lower-level kanji — **do not remove** just to tidy.
- Pure kana sentences.
- Katakana loanwords (unless annotating for consistency is harmless).

### 6.4 Furigana wrong / missing (always fix)

- Full-width parens `（よみ）` → `[よみ]`
- Bare N2/N1 kanji in N3/N45 sentence with no reading
- Bracket reading contradicts standard reading for that kanji in context
- Reversed or kanji-inside-brackets artifacts

### 6.5 JLPT level lookup for automation

There is **no** per-kanji JLPT table in the app DB today. Scheduled checks should either:

1. Use an external JLPT kanji list (recommended future: `audit/jlpt_kanji_levels.json`), or
2. Flag **unannotated kanji** in sentences and queue for human review, or
3. Cross-reference kanji against vocabulary tables in **higher-level** bundled DBs.

Until a kanji-level file exists, automations should at minimum enforce **Rule 0**, **Rule A**,
and **technical parse rules (§2)** on all rows, and flag unbracketed multi-kanji compounds
in lower decks for spot review.

---

## 7. Rule C — English translation

- **No raw Japanese** in `sentence_en` (no leftover `[かな]`, `(漢字)`, romaji glosses).
- Meaning must match `sentence_jp` (no extra clauses not in Japanese).
- Natural English at appropriate level; don't embed the headword in parentheses as a crutch.

---

## 8. Rule D — Japanese quality

- Natural collocations for the taught sense (not “友達と会議室で遊ぶ”).
- Two **different** scenarios across the pair of sentences.
- Appropriate register for level (N45 simpler; N1 may be formal/literary).
- No duplicate sentence pair copied onto another card.

---

## 9. Rule E — Card–sentence drift detection

Even when each sentence “looks fine” in isolation, compare **both sentences together** against
the vocab row:

| Signal | Likely cause |
|--------|----------------|
| Both sentences use reading X, card says reading Y | **Rule 0** — fix card row first |
| Sentences use different kanji for same target | Card kanji wrong or homograph mix-up |
| EN gloss on card fits sentence 1 but not sentence 2 | Card sense too narrow, or one sentence wrong |
| Sentences were written for an old headword | Regenerate after card fix |

Automation: if ≥1 sentence uses a reading/lemma that **never matches** the card’s
`kanji`+`reading`, flag **vocab id** for Rule 0 review before auto-rewriting sentences.

---

## 10. Rule F — Database & shipping

| Check | Requirement |
|-------|-------------|
| Integrity | `PRAGMA integrity_check = ok` after any write |
| FK | Every `example_sentences.vocab_id` exists in `vocabulary` |
| Count | 2 sentences per vocab card; 0 orphan sentences |
| Visibility | All shipped sentences `audit_status = 'verified'` |
| Backup | Timestamped `.bak` before batch writes |
| Git | `*.db` gitignored — release via local asset copy / build pipeline |

Assets path: `jlpt_vault/app/jlpt_vault/assets/vault_*.db`

---

## 11. Scheduled automation checklist

When a scheduled agent runs (weekly audit, pre-release QA, etc.), execute in order:

1. **Integrity** — all four `vault_*.db` files; `PRAGMA integrity_check`
2. **Vocab row lint (Rule 0)** — every `vocabulary` row:
   - kanji ↔ reading ↔ english_meaning internal consistency
   - POS/grammar tags leaked into fields
   - duplicate `(kanji, reading)` pairs
   - raw Japanese inside `english_meaning`
3. **Card–sentence drift (Rule E)** — sentences vs card row; flag ids where sentences
   systematically use a different lemma/reading than the card teaches
4. **Coverage** — each vocab id has ≥2 `verified` sentences; report ids with 0 or 1
5. **Sentence headword match (Rule A)** — each sentence uses the card’s taught form
6. **Parse lint (§2)** — full-width parens, unbalanced brackets, kana-in-brackets validity
7. **English lint (Rule C)** — regex for `[ぁ-んァ-ン一-龠]` inside `sentence_en`
8. **Furigana policy (Rule B)** — unbracketed above-level kanji (when kanji list available)
9. **Awkward template heuristic** — e.g. 友達+公園+遊, wrong-location collocations
10. **Report** — append to `audit/automation_YYYYMMDD.md`; split findings into:
    - `CARD_ROW` (Rule 0 — fix card first)
    - `SENTENCE` (Rule A — fix sentences)
    - `PARSE` / `EN` / `FURIGANA` (mechanical)

**Do not** auto-fix semantic/reading judgments unless the run mode is explicitly `auto-fix-safe`
and the fix is listed below.

Safe auto-fixes (mechanical only):

- `audit_status` → `verified` when content already correct
- Full-width `（` `）` → `[` `]`
- Strip raw Japanese from `english_meaning` or `sentence_en`
- Fix reversed furigana when reading is unambiguous
- Strip obvious POS tags from `kanji`/`reading` when pattern is unambiguous (e.g. `(かん)`)

Requires human or review-fix agent:

- Kanji/reading/meaning realignment on vocabulary row (**Rule 0**)
- Homograph split/merge, duplicate lemma resolution
- Wrong lexeme / wrong reading in sentences (**Rule A**)
- Sentence rewrite for naturalness
- Above-level kanji furigana additions (needs correct reading choice)

---

## 12. Examples (quick reference)

**Good N3 card 157 投げる / なげる**

```
公園[こうえん]で子供[こども]たちがボールを投[な]げています。
野球[やきゅう]の選手[せんしゅ]がボールを強[つよ]く投[な]げました。
```

**Bad — card row (Rule 0) before any sentence fix**

```
vocab: kanji=副  reading=とりわけ  EN=especially
→ 副 is read ふく, not とりわけ. Fix card to 取り分け / とりわけ first.
```

**Bad — wrong lemma for card 飯 / めし (Rule A)**

```
ご飯[ごはん]を食[た]べます。   ← uses ごはん, not めし
```

**Bad — parser**

```
会議室（かいぎしつ）で…   ← full-width parens; use 会議室[かいぎしつ]
```

**Bad — English**

```
I play in the meeting room (かいぎしつ).   ← raw Japanese in EN
```

---

## 13. Related files

| File | Purpose |
|------|---------|
| `audit/report_n*.md` | Batch audit logs |
| `audit/review_fixes_n*.md` | Applied REVIEW fixes |
| `audit/progress_n*.json` | Audit cursor state |
| `scripts/apply_second_sentences.py` | Insert missing 2nd sentences |
| `scripts/apply_sentence_fixes.py` | Apply curated sentence rewrites |
| `app/jlpt_vault/lib/study_arena.dart` | FuriganaText + study UI |
| `app/jlpt_vault/lib/database_helper.dart` | Sentence fetch + SRS |

---

## 14. Open gaps (not yet automated)

Consider adding later:

- `audit/jlpt_kanji_levels.json` — kanji → JLPT level for Rule B automation
- `audit/jlpt_reading_map.json` — kanji/word → valid readings for **Rule 0** automation
- `scripts/validate_cards.py` — implements §11 checklist (card rows first, then sentences)
- Per-card JLPT metadata for multi-kanji words
- Homograph / sense-id field when same kanji has multiple entries

---

*Last updated: 2026-06-26 — Rule 0 (vocab row triplet) added; audit order card-before-sentences.*
