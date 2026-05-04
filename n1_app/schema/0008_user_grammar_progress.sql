-- +goose Up
CREATE TABLE user_grammar_progress (
    id SERIAL PRIMARY KEY,
    grammar_id INTEGER UNIQUE REFERENCES grammar_rules(id) ON DELETE CASCADE,
    state TEXT DEFAULT 'new',
    interval_days INTEGER DEFAULT 0,
    ease_factor REAL DEFAULT 2.5,
    repetition_count INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    last_reviewed_at TIMESTAMP WITH TIME ZONE,
    next_review_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- +goose Down
DROP TABLE IF EXISTS user_grammar_progress;

