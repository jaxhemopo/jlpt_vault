-- +goose Up
ALTER TABLE vocabulary ADD COLUMN category VARCHAR(100);
ALTER TABLE vocabulary ADD COLUMN frequency_score INT DEFAULT 0;

-- +goose Down
ALTER TABLE vocabulary DROP COLUMN category;
ALTER TABLE vocabulary DROP COLUMN frequency_score;