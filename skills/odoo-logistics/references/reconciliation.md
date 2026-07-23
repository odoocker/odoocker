# Stripe / Shippo ↔ Odoo reconciliation surface

Scope for reconciling external payment (Stripe) and shipping (Shippo) records
against Odoo, through the read-only `odoo-logistics` skill.

**Status: confirmed by CFO (Penny) on GOL-65** (answering the open questions
raised on GOL-57). The logistics agent's reconciliation surface stays
**Odoo read-only** — no Stripe/Shippo API secrets. Every field below is already
covered by the model-level read allow-list in `models.md`, so no allow-list
widening was needed; this doc just names the reconcilable fields explicitly.

## Separation of duties (the controlling decision)

Otto's need is **operational**, not financial: *"is this order paid before I
fulfill it?"* and *"does the Shippo/UPS charge tie to a real picking?"* Both are
answerable from Odoo read-only fields; Otto never calls the Stripe or Shippo API
directly.

**True financial reconciliation is a CFO function** — matching Stripe payout
*batches* to bank deposits, booking processor fees/chargebacks, reconciling
Shippo *invoices* vs. labels at month-close. Those need the processor/carrier
secrets and are scoped to the **CFO agent under a separate, off-critical-path
issue** (Stripe restricted read-only key + Shippo read), never bundled into the
logistics agent's runtime. Keeping whoever moves inventory away from
payment-processor keys is the least-privilege control an auditor expects.

## The Odoo side — reconcilable read surface

### Stripe ↔ `payment.transaction` (read-only)

| Field                                | Use                                                      |
| ------------------------------------ | -------------------------------------------------------- |
| `provider_reference`                 | **Join key** → Stripe charge / payment-intent id         |
| `reference`                          | Internal order reference → join back to `sale.order`     |
| `amount`, `currency`                 | Match charge amount                                      |
| `state`                              | draft/pending/authorized/done/cancelled/error — Otto's "is it paid?" signal |
| `create_date` / `last_state_change`  | Reconciliation timing window                            |
| `sale_order_ids` (link to sale.order)| Tie transaction to the order it paid for                |

### Shippo ↔ `stock.picking` (outgoing, read-only)

| Field                                    | Use                                                  |
| ---------------------------------------- | ---------------------------------------------------- |
| `carrier_tracking_ref`                   | **Join key** → Shippo tracking number                |
| `carrier_id` → `delivery.carrier`.`name` | Which carrier                                        |
| `shipping_weight` / `weight`             | Validates DIM-rate billing (per-tree DIM model, PR #13) |
| `date_done`                              | Ship date                                            |
| `sale_id` (link to sale.order)           | Tie the picking to its order                          |

### Shipping/label cost — where it lands (confirmed)

There is **no standard "actual billed label cost" field on `stock.picking`** in
Odoo community. The **quoted rate** (what the customer was charged, driven by our
per-tree DIM model) lands on the **`sale.order` delivery line**:
`sale.order.line` with `is_delivery = True`, read `price_subtotal` /
`price_unit`. `sale.order` and `sale.order.line` are both in the read allow-list,
so this number is readable now.

The **actual amount Shippo billed us** for the label is not in Odoo — it lives in
the Shippo transaction and is only reachable once the CFO-scoped Shippo read key
is wired up (separate issue). Reconciliation of quoted-rate (Odoo) vs.
billed-label (Shippo) is therefore a CFO-agent job, not Otto's.

## Supporting Odoo models (available now, read-only)

| Purpose                       | Model / fields                                                    |
| ----------------------------- | ---------------------------------------------------------------- |
| Sales orders (what was sold)  | `sale.order`: name, partner_id, amount_total, state, date_order  |
| Order lines                   | `sale.order.line`: product_id, product_uom_qty, price_subtotal, is_delivery |
| Customer invoices / credit    | `account.move` (invoice/refund): name, amount_total, ref         |
| Payments                      | `account.payment`: amount, payment_method_line_id, ref, date     |
| Carriers                      | `delivery.carrier`: name, delivery_type                          |

## Reconciliation cadence & authoritative source

- **Operational (Otto, per-order):** before fulfilling, confirm
  `payment.transaction.state = done` for the order; after shipping, confirm the
  picking's `carrier_tracking_ref` exists and ties to a real `sale.order`. Odoo
  is authoritative for this "is it paid / did it ship?" check.
- **Financial (CFO, month-close):** Stripe payout batches ↔ bank deposits and
  Shippo invoices ↔ labels, booking fees/chargebacks. Authoritative source is
  the processor/carrier statement, reconciled *to* Odoo. Runs under the CFO
  agent with scoped secrets, off this skill.

## Why the amount/fee fields matter (books / tax)

These figures must be capturable for the books at close, so they belong in the
read surface now rather than surfacing as a gap at tax time — **Schedule F**:

- Outbound freight / shipping → **Line 32 (other expenses)**.
- Stripe processing fees → **Line 32 (merchant / bank fees)**. (Note: the *fee*
  amount itself is a Stripe balance-transaction field, not stored on
  `payment.transaction`; captured via the CFO-scoped Stripe read key at close.)

## Deferred: CFO-scoped external read access

Reconciling *against* Stripe and Shippo (payout batches, balance transactions
with fees, Shippo invoices) requires read access to those APIs — **separate
secrets, not part of this Odoo skill**. Per Penny (GOL-65), if/when real money
reconciliation is wanted she'll raise it as its own issue under the CFO agent
(Stripe **restricted read-only** key + Shippo read), off GOL-60's critical path.
Do not embed those keys in the logistics agent config.
