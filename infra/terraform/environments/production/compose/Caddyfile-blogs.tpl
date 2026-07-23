# Caddyfile for the production blogs droplet.
# TLS: Cloudflare Origin CA certs (files under /certs, mounted ro).
# All hostnames are Cloudflare-proxied; the CF edge holds the public cert.

gatheringatthegrove.com {
	tls /certs/gatheringatthegrove.com.pem /certs/gatheringatthegrove.com.key
	reverse_proxy ghost-hub:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}

blog.gatheringatthegrove.com {
	tls /certs/gatheringatthegrove.com.pem /certs/gatheringatthegrove.com.key
	header X-Robots-Tag "noindex, nofollow"
	reverse_proxy ghost-hub:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}

goldberrygrove.farm {
	tls /certs/goldberrygrove.farm.pem /certs/goldberrygrove.farm.key
	reverse_proxy ghost-goldberry:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}

blog.goldberrygrove.farm {
	tls /certs/goldberrygrove.farm.pem /certs/goldberrygrove.farm.key
	header X-Robots-Tag "noindex, nofollow"
	reverse_proxy ghost-goldberry:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}

blog.woodworkingeorge.com {
	tls /certs/woodworkingeorge.com.pem /certs/woodworkingeorge.com.key
	header X-Robots-Tag "noindex, nofollow"
	reverse_proxy ghost-ggg:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}

blog.atthegrovenursery.com {
	tls /certs/atthegrovenursery.com.pem /certs/atthegrovenursery.com.key
	header X-Robots-Tag "noindex, nofollow"
	reverse_proxy ghost-nursery:2368 {
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}
