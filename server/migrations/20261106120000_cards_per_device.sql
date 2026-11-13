-- ADR-093 (docs/security-review-2026-11.md, server-http:10, the card window).
-- One card per chat let a member's garbage card stand for the whole epoch
-- (the epoch's author's, ADR-090, may be the member who sent garbage). Now
-- every device in the chat keeps its own card (its MLS GroupInfo) and a new
-- phone reads them all: honest members' cards agree, and it trusts the one
-- its own person or most people left. The epoch's author no longer matters.
DELETE FROM group_cards;
ALTER TABLE group_cards DROP CONSTRAINT group_cards_pkey;
ALTER TABLE group_cards ADD COLUMN device_pk BYTEA NOT NULL REFERENCES devices(device_pk) ON DELETE CASCADE;
ALTER TABLE group_cards ADD PRIMARY KEY (group_id, device_pk);
ALTER TABLE mls_groups DROP COLUMN epoch_committer_device_pk;
