-- Tech-debt 4.2 — QR pairing of a new device (ADR-025).
--
-- The new device shows a QR: a random 16-byte pairing id + a one-time
-- HPKE public key. The existing device seals the account secret to that
-- key and leaves it here under the id; the new device takes it (once).
-- The server never sees the key (it's only in the QR), so it can neither
-- read the secret nor substitute its own. Entries live 10 minutes.
CREATE TABLE IF NOT EXISTS pairing_mailbox (
    pairing_id  BYTEA       NOT NULL PRIMARY KEY,
    ciphertext  BYTEA       NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    CONSTRAINT pairing_id_len CHECK (octet_length(pairing_id) = 16)
);
CREATE INDEX IF NOT EXISTS pairing_mailbox_expires ON pairing_mailbox (expires_at);
