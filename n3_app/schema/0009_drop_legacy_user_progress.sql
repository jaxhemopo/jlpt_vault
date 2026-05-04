-- +goose Up
-- +goose StatementBegin
DROP TABLE IF EXISTS user_progress;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
CREATE TABLE user_progress (
    user_id UUID NOT NULL,
    vocab_id INTEGER REFERENCES vocabulary(id) ON DELETE CASCADE,
    ease_factor FLOAT DEFAULT 2.5,
    interval INT DEFAULT 0,
    repetition INT DEFAULT 0,
    next_review_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, vocab_id)
);
-- +goose StatementEnd
