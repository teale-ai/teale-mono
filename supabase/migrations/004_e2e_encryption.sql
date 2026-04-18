-- Migration: E2E encrypted messages
-- All messages are now encrypted client-side before storage.

-- Replace plaintext content with encrypted fields
ALTER TABLE messages DROP COLUMN IF EXISTS content;
ALTER TABLE messages ADD COLUMN encrypted_content TEXT NOT NULL;
ALTER TABLE messages ADD COLUMN encryption_key_id TEXT NOT NULL;

-- Track key rotation epoch on conversations
ALTER TABLE conversations ADD COLUMN group_key_version INT NOT NULL DEFAULT 1;

-- Index for key ID lookups
CREATE INDEX IF NOT EXISTS idx_messages_encryption_key_id ON messages(encryption_key_id);
