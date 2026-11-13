-- ADR-025 — a queued Welcome addressed to one device of the recipient
-- (NULL: any of their devices, as before). Delivered → deleted, instead of
-- staying until the TTL for people with several devices.
ALTER TABLE pending_welcomes ADD COLUMN IF NOT EXISTS recipient_device_pk BYTEA;
