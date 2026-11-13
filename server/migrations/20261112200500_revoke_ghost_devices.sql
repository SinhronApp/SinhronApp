-- PREV-8 (server-http:2) — before 2026-11 a registration could hang a key
-- that is not the identity key on an account as a "device" with no
-- certificate. New ones can't appear; the old rows were never cleaned and
-- KeyPackage upload, push tokens, backup marks and group cards still took
-- them. Every app registers the identity key itself as its first device
-- and links the others with a certificate, so no honest device matches.
UPDATE devices d SET revoked_at = NOW()
FROM users u
WHERE u.user_pk = d.user_pk
  AND d.certificate IS NULL
  AND d.device_pk <> u.identity_pubkey
  AND d.revoked_at IS NULL;
