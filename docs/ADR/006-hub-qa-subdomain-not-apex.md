# ADR 006: QA hub serves at `hub.qa.*`, not the apex

**Status:** Accepted
**Date:** 2026-06-26
**Deciders:** Josh Dunbar
**PRs:** [grove-sites #26](https://github.com/Goldberry-Playground/grove-sites/pull/26), [odoocker inline workaround applied to live droplet 2026-06-26]

## Context

The QA environment originally routed the hub frontend at `https://qa.gatheringatthegrove.com` (the apex of the delegated zone). The 3 tenant frontends used `<tenant>.qa.gatheringatthegrove.com` subdomain pattern.

This worked fine until 2026-06-26, when the apex cert hit LE's "5 certs per exact set of identifiers per 168h" rate limit. The combined `{qa.gatheringatthegrove.com, *.qa.gatheringatthegrove.com}` identifier set exhausted after ~6 droplet recreates. The wildcard cert was already issued (covers all 1-level subdomains per RFC 6125), but the apex specifically did NOT have a valid cert and couldn't get one until ~21:30 UTC the next day.

Routing requests to `qa.gatheringatthegrove.com` failed with TLS handshake errors:
```
LibreSSL/3.3.6: error:1404B438:SSL routines:ST_CONNECT:tlsv1 alert internal error
```

The 3 tenant URLs continued working fine because the wildcard cert covers them.

## Decision

**Route the hub frontend through a `hub.qa.gatheringatthegrove.com` subdomain instead of the apex.**

Concrete changes:

1. **DO DNS zone**: add a CNAME `hub` → `@` in `qa.gatheringatthegrove.com`
2. **Caddyfile.tpl**: the existing site block matching `qa.gatheringatthegrove.com, *.qa.gatheringatthegrove.com` already covers `hub.qa.*` via the wildcard part; just add a `@hub_sub host hub.qa.gatheringatthegrove.com` matcher + handle block routing to `hub:3000`
3. **grove-sites `packages/ui/src/sibling-sites.ts`**: change `QA_SITES[0].href` from `https://qa.gatheringatthegrove.com` to `https://hub.qa.gatheringatthegrove.com` — the SiblingStrip + footers across all 4 apps now link to the new URL

## Why this works

Per RFC 6125 SNI matching rules:
- `*.qa.gatheringatthegrove.com` matches `foo.qa.gatheringatthegrove.com`, `bar.qa.gatheringatthegrove.com`, `hub.qa.gatheringatthegrove.com`
- `*.qa.gatheringatthegrove.com` does NOT match `qa.gatheringatthegrove.com` (the bare apex)

So an "apex hub + subdomain tenants" pattern needs TWO LE identifier sets — one for the apex alone, one for the wildcard. Routing hub through a subdomain means we only need ONE identifier set (the wildcard), which already exists.

## Alternatives considered

### "Wait for LE to clear and provision the apex cert when budget allows"

Would work as a tactical fix but leaves the structural problem in place — every future cert rate-limit incident would re-create the same hub-down-for-24h symptom. Rejected as a permanent solution.

### "Split the Caddyfile into two site blocks (apex + wildcard) for fresh identifier-set budgets"

Each split block gets its own 5/week from scratch. Doesn't solve the structural issue — the apex would still need its own cert, frequent recreates would still eat the new budget. Useful as a temporary workaround at best.

### "Use a `0.0.0.0` SAN trick or self-signed apex cert"

Apex `qa.gatheringatthegrove.com` would render a TLS warning. Worse UX than just using a different URL. Rejected.

### "Move QA off DO DNS to Cloudflare with origin certs (no LE involvement)"

Cloudflare origin certs are long-lived and don't have rate limits. But: restructuring DNS delegation back to Cloudflare is a multi-day project, and the rate-limit problem itself is already solved by ADR-005's persistent-volume stack. Overkill.

## Consequences

**Positive:**
- Pattern consistency: all 4 frontends follow `<service>.qa.*`
- Zero apex cert dependency — QA env never needs a cert for the bare `qa.gatheringatthegrove.com`
- No new LE rate-limit identifier set introduced (the existing wildcard already covered the new subdomain)
- Verified working: `https://hub.qa.gatheringatthegrove.com` returns 200 with valid wildcard cert

**Negative:**
- Diverges from the prod pattern (`gatheringatthegrove.com` IS the apex for hub in production). Cross-env URL prediction is slightly less obvious — prod hub = apex, QA hub = `hub.<env>`. Mitigated by `sibling-sites.ts` having a single source of truth that's env-aware.
- Apex `qa.gatheringatthegrove.com` still exists in the Caddyfile (to enable a cert if/when LE allows) but no service is routed to it — slight clutter. Acceptable; signals "this hostname exists" without committing to serving it.

**Open items:**
- Worth considering whether prod should ALSO follow this pattern (`hub.gatheringatthegrove.com`, apex redirects). Would eliminate the apex-vs-wildcard cert asymmetry uniformly. Not blocking; revisit when next refactoring prod's DNS.

## References

- [RFC 6125 §6.4.3 — wildcard cert matching](https://datatracker.ietf.org/doc/html/rfc6125#section-6.4.3)
- ADR-005 (this PR's sibling) — the broader cert resilience stack
- [Memory: qa-hub-subdomain-convention](../../../../../../../.claude/projects/-Users-joshuadunbar-Documents-Dev-Projects-gather-at-the-grove/memory/project_qa_hub_subdomain_convention.md) — operator-facing summary
- grove-sites #26 — the single-line URL flip + comment explaining why
