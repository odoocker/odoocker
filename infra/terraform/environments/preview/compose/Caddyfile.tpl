# Grove Preview -- Caddy config (templated at boot via cloud-init).
# Substituted variables: PREVIEW_HOST, PREVIEW_ZONE
#
# Caddy terminates TLS on 443 using DO DNS-01 (no inbound port-80 listener
# needed for ACME -- DO controls the DNS for preview.gatheringatthegrove.com,
# Caddy uses the DO_API_TOKEN to write the _acme-challenge TXT record).
#
# Routing model: each tenant has its own CNAME under the preview host
# (e.g. hub.pr-104-x7q2k.preview.gatheringatthegrove.com), so Caddy matches
# by leftmost label and reverse-proxies to the right container.

{
	email ops@goldberrygrove.farm
	# Wildcard TLS via DNS-01 -- needs the DO DNS plugin in the Caddy image
	# (see docker-compose.preview.yml: image: ghcr.io/goldberry-playground/
	# grove-caddy -- xcaddy-built with caddy-dns/digitalocean baked in).
}

# Match any of our 5 tenant subdomains under this preview's host.
*.${PREVIEW_HOST}.${PREVIEW_ZONE} {
	tls {
		# Multi-issuer fallback mirrors QA's PR-D (#98) pattern. Primary
		# tries whatever ACME_CA env says (defaults to LE prod); fallback
		# uses LE staging if prod 429s. Preview's per-PR identifier sets
		# (unique 5-char-suffix host label) mean rate-limit risk is lower
		# than QA's, but the fallback costs nothing to add and matches
		# the QA pattern -- worth doing for consistency.
		# Caddy subdirective for ACME directory URL inside `issuer acme {}` is
		# `dir`, not `ca` (`acme_ca` only works as global option). PR #116
		# fixed the crashloop this caused in QA on 2026-06-27.
		issuer acme {
			dir {env.ACME_CA}
			dns digitalocean {env.DO_API_TOKEN}
		}
		issuer acme {
			dir https://acme-staging-v02.api.letsencrypt.org/directory
			dns digitalocean {env.DO_API_TOKEN}
		}
	}

	# Public-but-not-indexed -- robot.txt + headers belt-and-suspender
	header X-Robots-Tag "noindex, nofollow"
	header Cache-Control "no-store"

	handle /robots.txt {
		respond "User-agent: *
Disallow: /" 200
	}

	# Route by leftmost label. Containers listen internally:
	#   hub       → 3000  (hub Dockerfile sets ENV PORT=3000)
	#   goldberry → 3001  (storefront Dockerfiles set ENV PORT=3001)
	#   ggg       → 3001
	#   nursery   → 3001
	#   odoo      → 8069
	@hub host hub.${PREVIEW_HOST}.${PREVIEW_ZONE}
	@goldberry host goldberry.${PREVIEW_HOST}.${PREVIEW_ZONE}
	@ggg host ggg.${PREVIEW_HOST}.${PREVIEW_ZONE}
	@nursery host nursery.${PREVIEW_HOST}.${PREVIEW_ZONE}
	@odoo host odoo.${PREVIEW_HOST}.${PREVIEW_ZONE}

	handle @hub { reverse_proxy hub:3000 }
	handle @goldberry { reverse_proxy goldberry:3001 }
	handle @ggg { reverse_proxy ggg:3001 }
	handle @nursery { reverse_proxy nursery:3001 }
	handle @odoo { reverse_proxy odoo:8069 }

	handle {
		respond "Unknown preview tenant" 404
	}
}
