-- +goose Up
-- +goose StatementBegin
ALTER TABLE vocabulary ADD CONSTRAINT unique_kanji_reading UNIQUE (kanji, reading);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE vocabulary DROP CONSTRAINT unique_kanji_reading;
-- +goose StatementEnd