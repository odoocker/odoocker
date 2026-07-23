# Grove Preview — Sanitization Contract

This file is the authoritative PII contract. The sanitizer enforces exactly this list — nothing more, nothing less. Any column not listed is preserved as-is.

**Status:** Frozen 2026-06-01. Reviewed against `grove_headless@eda2791` ("feat(grove_headless): grove_slug field + slug lookup endpoint").

## Direct PII — column rewrites (in `sanitize_dump.py`)

| Table | Column | Replacement strategy |
|---|---|---|
| `res_partner` | `email` | `pii-{id}@preview.local` |
| `res_partner` | `phone` | `NULL` |
| `res_partner` | `mobile` | `NULL` |
| `res_partner` | `vat` | `NULL` |
| `res_partner` | `street` | `123 Preview Lane` |
| `res_partner` | `street2` | `NULL` |
| `res_partner` | `zip` | `00000` |
| `res_partner` | `name` | `Customer {id}` |
| `res_users` | `login` | `user{id}@preview.local` |
| `res_users` | `password` | bcrypt of `preview` (precomputed: `$2b$12$aqLqsRzRYZlLYxlEFO6cJOEW9s84eiA/4IRSuQkw0ufC//2p.cTmi`) |
| `res_users` | `signature` | `NULL` |
| `mail_message` | `body` | `[REDACTED preview content]` (where `author_id` IS NOT NULL) |
| `mail_message` | `subject` | `[REDACTED]` (where `author_id` IS NOT NULL) |
| `mail_tracking_value` | `old_value_text` | `NULL` |
| `mail_tracking_value` | `new_value_text` | `NULL` |
| `audittrail_log_line` | `old_value` | `NULL` |
| `audittrail_log_line` | `new_value` | `NULL` |
| `payment_transaction` | `provider_reference` | `NULL` |
| `payment_transaction` | `acquirer_reference` | `NULL` |

**`grove_headless` additions:** none. See "grove_headless review" below for what was inspected and why each field was left out.

## Delete-rows tables (in `post-restore-purge.sql`)

Tables whose every row is dropped after restore:

- `payment_token`
- `res_partner_bank`
- `mail_notification`
- `bus_bus`

## Explicitly preserved (do not touch)

- `sale_order` line items, totals, statuses
- `product_template`, `product_product`, `product_attribute_*` (including the `grove_seo_description` and `grove_slug` columns added by `grove_headless` — public marketing copy and URL slugs, not PII)
- `stock_move`, `stock_quant`
- `account_journal`, `account_move`
- `crm_lead` IDs/stages
- `grove_potting_batch` (all columns, including the staff-authored `notes` field — see review notes)
- All other `grove_headless` custom tables

## grove_headless review

Audit performed 2026-06-01 against `grove_headless@eda2791`. Module contains three model files (`product_template.py`, `potting_batch.py`, `website.py`). All `fields.Text` / `fields.Char` / `fields.Html` declarations were inventoried:

| Field | Type | Source | Verdict |
|---|---|---|---|
| `product_template.grove_seo_description` | Text | Marketing/SEO staff | **Preserve** — public website content, intentionally crawlable |
| `product_template.grove_slug` | Char | Marketing/SEO staff | **Preserve** — URL slug, public identifier |
| `grove.potting.batch.name` | Char | Auto-generated via `ir.sequence` | **Preserve** — system-generated reference (e.g. `PB-001`) |
| `grove.potting.batch.notes` | Text | Nursery staff | **Preserve** — operational notes about plant movements ("lost 5 to overwatering"); not customer-entered, content domain (plants × pot sizes) makes incidental PII leakage negligible. Reconsider if this field's usage shifts toward customer correspondence. |

The standard `mail_message.body` redaction (where `author_id IS NOT NULL`) already covers the case where staff paste customer details into Odoo's mail-thread discussions, including discussions attached to `grove.potting.batch` records via the `mail.thread` mixin.

## Rules for amendments

- Adding a column rewrite: append a row to "Direct PII" + add a test case in `test_sanitize_dump.py`
- Adding a delete-rows table: append to list + add an integration test in `test_post_restore.py`
- Removing anything: requires explicit code review + sign-off (this is a contract)
- Re-running the `grove_headless` audit: required whenever a new free-text field is added to a customer-facing model in that module
