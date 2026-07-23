# Scoped Odoo models & security groups

The access policy lives in `scripts/odoo_client.py` (`READ_MODELS`,
`WRITE_MODELS`, `BLOCKED_METHODS`). This doc explains the intent and maps the
models to the Odoo security groups the `logistics-otto` user is granted.

## Odoo groups granted to `logistics-otto`

Provisioned by `scripts/provision_logistics_user.py`:

| Group (xml_id)                     | Grants                                    |
| ---------------------------------- | ----------------------------------------- |
| `stock.group_stock_user`           | Inventory operations (moves, pickings)    |
| `stock.group_stock_manager`        | Inventory adjustments / config            |
| `purchase.group_purchase_user`     | Create & manage purchase orders           |
| `sales_team.group_sale_salesman`   | Read sales orders (own + team)            |
| `uom.group_uom`                    | Multiple units of measure                 |
| `product.group_stock_packaging`    | Product packaging (box-fit per product)   |

Explicitly **not** granted: Settings/Administration, Accounting, user
management, or Website. That keeps the account least-privilege at the Odoo
layer; the client allow-lists are defense-in-depth on top.

## Read allow-list

Products & master data: `product.template`, `product.product`,
`product.category`, `product.pricelist`, `product.pricelist.item`,
`product.supplierinfo`, `product.packaging`, `uom.uom`, `uom.category`.

Inventory: `stock.quant`, `stock.move`, `stock.move.line`, `stock.picking`,
`stock.picking.type`, `stock.location`, `stock.warehouse`,
`stock.warehouse.orderpoint`, `stock.lot`, `stock.scrap`.

Purchasing: `purchase.order`, `purchase.order.line`.

Sales (read-only): `sale.order`, `sale.order.line`.

Shipping: `delivery.carrier`, `stock.package.type`.

Partners (read-only): `res.partner`.

Reconciliation (read-only): `account.move`, `account.move.line`,
`account.payment`, `payment.transaction`.

## Write allow-list (create/write, `--confirm` required)

`product.template`, `product.product`, `product.category`, `product.pricelist`,
`product.pricelist.item`, `product.supplierinfo`, `product.packaging`,
`stock.quant`, `stock.move`, `stock.move.line`, `stock.picking`,
`stock.warehouse.orderpoint`, `stock.lot`, `stock.scrap`, `purchase.order`,
`purchase.order.line`, `delivery.carrier`, `stock.package.type`.

`stock.lot` is Odoo 19's model for production/tracking lots (formerly
`stock.production.lot`) — use `stock.lot` for FEFO/expiry on flour, nuts, fruit.

## Field-level gate (writable model, gated field)

- `purchase.order.state` — **refused.** Building/editing PO *drafts* is allowed,
  but confirming a PO (state → `purchase`/`done`) commits binding spend and is
  **CFO-only** (routes through Penny; landed-cost review). Draft here, hand off
  the confirmation. Enforced by `WRITE_FIELD_BLOCKLIST` in `odoo_client.py`; the
  tool also does not expose `button_confirm` at all.

## Deferred — not in this policy (v2 follow-up)

- **MRP / BoMs** (`mrp.bom`, `mrp.bom.line`, `mrp.*`) — e.g. chestnut flour
  milled from raw nuts, gift kits. Deferred to a v2 follow-up (food/wood lines
  are greenfield with no Odoo data yet, and MRP may not be installed). Tracked
  separately; re-open the allow-list when the milled/kitted product lines land.

## Never allowed

- `unlink` (delete) on any model.
- Any write to `account.*`, `payment.transaction`, `sale.order`,
  `sale.order.line`, `res.partner` (money / revenue / CRM stay read-only here).

## Changing the policy

Widen or narrow the allow-lists by editing the sets in `odoo_client.py` and, if
needed, the group list in `provision_logistics_user.py`. Both are intended to be
reviewed on [GOL-57](/GOL/issues/GOL-57). Do not bypass the client by embedding
raw XML-RPC calls in a heartbeat.
