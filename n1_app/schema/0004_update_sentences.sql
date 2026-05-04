-- +goose Up
ALTER TABLE example_sentences 
ADD COLUMN sentence_type TEXT, -- 'daily' or 'formal'
ADD COLUMN grammar_level TEXT; -- 'N4', 'N3', etc.

-- +goose Down
ALTER TABLE example_sentences 
DROP COLUMN sentence_type, 
DROP COLUMN grammar_level;