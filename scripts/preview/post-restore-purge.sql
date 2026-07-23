-- Grove Preview — post-restore purge
-- Run after psql restore of a sanitized dump. Drops rows from tables the sanitizer
-- preserves structurally (so referential integrity holds during restore) but whose
-- contents are entirely PII or financial.
--
-- Contract: docs/preview/sanitize-contract.md (Delete-rows tables)

BEGIN;

DELETE FROM payment_token;
DELETE FROM res_partner_bank;
DELETE FROM mail_notification;
DELETE FROM bus_bus;

COMMIT;

-- Verification queries (must all return 0):
SELECT 'payment_token' AS table_name, COUNT(*) AS remaining FROM payment_token
UNION ALL SELECT 'res_partner_bank', COUNT(*) FROM res_partner_bank
UNION ALL SELECT 'mail_notification', COUNT(*) FROM mail_notification
UNION ALL SELECT 'bus_bus', COUNT(*) FROM bus_bus;
