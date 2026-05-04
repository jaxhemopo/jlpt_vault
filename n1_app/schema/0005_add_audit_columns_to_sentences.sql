-- +goose Up
-- +goose StatementBegin
ALTER TABLE example_sentences ADD COLUMN audit_status TEXT DEFAULT 'pending';
ALTER TABLE example_sentences ADD COLUMN audit_comment TEXT;

-- Create an index to speed up the auditing script's queries
CREATE INDEX idx_sentences_audit_status ON example_sentences(audit_status);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX idx_sentences_audit_status;
ALTER TABLE example_sentences DROP COLUMN audit_comment;
ALTER TABLE example_sentences DROP COLUMN audit_status;
-- +goose StatementEnd