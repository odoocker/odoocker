# Grove CostOps — DO billing bridge

Ships DigitalOcean spend into OpenObserve as metrics, so "what we spend and what
to trim" lives in the same pane as the USE/utilization metrics (spec
`docs/specs/2026-06-26-grove-observability-design.md` §6). Sprint-1 CostOps core.

## How it works

```
supercronic (crontab, hourly)
   └─ do_billing_bridge.py
        ├─ GET /v2/customers/my/balance        → cost_account_* (the ACTUAL truth)
        ├─ GET /v2/{droplets,databases,apps,volumes}  × static price list
        │                                       → cost_resource_monthly_estimate (DERIVED)
        └─ POST OTLP metrics → OpenObserve
```

Metrics (queried by the `cost-*` alerts + the rightsizing dashboard):

| Metric | Source | Tags |
|---|---|---|
| `cost_account_month_to_date` | `/balance` MTD balance | `env` |
| `cost_account_balance` | `/balance` account balance | `env` |
| `cost_account_month_to_date_usage` | `/balance` MTD usage | `env` |
| `cost_resource_monthly_estimate` | inventory × price list | `type`, `name`, `size`, `env` |

## The account/resource split (important)

- **`cost_account_*` is the clean actual** — straight from DO's balance API, no pricing guesswork.
- **`cost_resource_*` is a derived estimate** — DO billing is invoice-grained, not per-resource-itemized (unlike AWS CUR), so per-resource cost is *live inventory × a static price list* (`DROPLET_PRICES` etc. in `do_billing_bridge.py`). Unknown size slugs price to `0.0` **and log** — so pricing drift is visible, never silent. Update the tables when DO changes pricing.

Joined with the USE metrics in OpenObserve, `cost_resource_monthly_estimate × low-utilization` is the **rightsizing / "what to trim"** view.

## Gating

OFF unless `COST_BRIDGE_ENABLED=true` **and** `DO_API_TOKEN` is set (a **read-only** DO token). Cloud-only — there's no DO account to bill against locally.

## Run / debug

```bash
# Whole monitoring stack (bridge comes up under the monitoring compose):
make monitoring-up

# One-off, against a running OpenObserve:
COST_BRIDGE_ENABLED=true DO_API_TOKEN=dop_v1_... COST_ENV=prod \
OPENOBSERVE_OTLP_METRICS_URL=http://localhost:5080/api/default/v1/metrics \
OPENOBSERVE_ROOT_EMAIL=... OPENOBSERVE_ROOT_PASSWORD=... \
python3 do_billing_bridge.py

# Unit-test the pricing + OTLP builder (no token / network needed):
python3 test_do_billing_bridge.py
```

> **Pending live validation:** the OTLP ingest path/auth and the exact DO list shapes are the documented contracts (balance struct verified against `godo`), but the end-to-end poll → ingest hasn't been exercised with a real token yet — confirm on first enable. **Sprint 2** adds Infracost (pre-merge $/mo delta on TF PRs) as the shift-left complement.
