-- +goose Up
CREATE TABLE grammar_rules (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    structure TEXT,
    meaning TEXT,
    grammar_level VARCHAR(10) DEFAULT 'N2'
);

CREATE TABLE grammar_cards (
    id SERIAL PRIMARY KEY,
    grammar_id INTEGER REFERENCES grammar_rules(id),
    sentence_jp TEXT NOT NULL,         -- Full sentence with furigana
    sentence_en TEXT NOT NULL,         -- English translation
    cloze_sentence_jp TEXT NOT NULL,   -- Sentence with [____]
    cloze_answer VARCHAR(255) NOT NULL, -- The piece that goes in the blank
    audit_status VARCHAR(50) DEFAULT 'pending'
);
-- +goose Down
DROP TABLE grammar_cards;
DROP TABLE grammar_rules;
