-- +goose Up
-- +goose StatementBegin
CREATE TABLE vocabulary (
    id SERIAL PRIMARY KEY,
    kanji VARCHAR(255),
    reading VARCHAR(255) NOT NULL,
    english_meaning TEXT NOT NULL,
    jlpt_level INT DEFAULT 3
);

CREATE TABLE example_sentences (
    id SERIAL PRIMARY KEY,
    vocab_id INTEGER REFERENCES vocabulary(id) ON DELETE CASCADE,
    sentence_jp TEXT NOT NULL,
    sentence_en TEXT NOT NULL,
    cloze_deletion_index INT -- Store which part of the sentence is the "blank"
);

CREATE TABLE user_progress (
    user_id UUID NOT NULL,
    vocab_id INTEGER REFERENCES vocabulary(id) ON DELETE CASCADE,
    ease_factor FLOAT DEFAULT 2.5, -- How "easy" the word is
    interval INT DEFAULT 0,        -- Days until next review
    repetition INT DEFAULT 0,      -- Number of successful reviews
    next_review_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, vocab_id)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE user_progress;
DROP TABLE example_sentences;
DROP TABLE vocabulary;
-- +goose StatementEnd
