-- +goose Up
-- +goose StatementBegin
CREATE TABLE user_vocabulary_progress (
    id SERIAL PRIMARY KEY,
    vocab_id INT UNIQUE REFERENCES vocabulary(id) ON DELETE CASCADE,
    
    -- SRS Metrics
    state TEXT DEFAULT 'new', -- 'new', 'learning', 'review', 'relearning'
    interval_days INT DEFAULT 0,
    ease_factor DECIMAL DEFAULT 2.5, -- Standard Anki ease factor
    repetition_count INT DEFAULT 0,
    lapses INT DEFAULT 0,
    
    -- Timing
    last_reviewed_at TIMESTAMP,
    next_review_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE user_vocabulary_progress;
-- +goose StatementEnd