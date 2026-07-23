// Bootstrap a Ghost instance + emit its Content API key. Node port of
// grove-odoo-modules' setup_ghost_integration.py, self-contained so the QA
// droplet needs NOTHING from other repos -- it runs INSIDE the ghost
// container via `docker compose exec -T ghost-<t> node < this-file` (the
// ghost:5 image ships node 18+, which has global fetch).
//
// Idempotent: skips setup if the admin exists; reuses the integration by
// name, so re-runs return the SAME key.
//
// Env in (via docker exec -e):
//   GHOST_URL              base URL to call (http://localhost:<port> inside the container)
//   GHOST_ORIGIN           Origin header value -- the container's configured
//                          `url` (e.g. http://ghost-goldberry:2368). Ghost's
//                          admin session auth checks Origin against its url.
//   GHOST_ADMIN_EMAIL      required
//   GHOST_ADMIN_PASSWORD   required
//   GHOST_ADMIN_NAME       display name (default "Site Admin")
//   GHOST_BLOG_TITLE       blog title on first setup (default "Ghost Blog")
//   GHOST_INTEGRATION_NAME integration to find-or-create (default "Headless Frontend")
//
// Out: single line `GHOST_CONTENT_KEY=<key>` on stdout; progress on stderr.
// Exit 1 on any failure.

const BASE = (process.env.GHOST_URL || "http://localhost:2368").replace(/\/+$/, "");
const ORIGIN = process.env.GHOST_ORIGIN || BASE;
const EMAIL = process.env.GHOST_ADMIN_EMAIL;
const PASSWORD = process.env.GHOST_ADMIN_PASSWORD;
const NAME = process.env.GHOST_ADMIN_NAME || "Site Admin";
const TITLE = process.env.GHOST_BLOG_TITLE || "Ghost Blog";
const INTEGRATION = process.env.GHOST_INTEGRATION_NAME || "Headless Frontend";

function fail(msg) {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
}

if (!EMAIL || !PASSWORD) fail("GHOST_ADMIN_EMAIL and GHOST_ADMIN_PASSWORD are required");

let cookie = "";

async function call(method, path, body) {
  const headers = { Origin: ORIGIN };
  if (cookie) headers.Cookie = cookie;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const resp = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  // Capture the admin session cookie when Ghost sets it.
  const setCookies = resp.headers.getSetCookie
    ? resp.headers.getSetCookie()
    : [resp.headers.get("set-cookie")].filter(Boolean);
  const session = setCookies.find((c) => c.startsWith("ghost-admin-api-session"));
  if (session) cookie = session.split(";")[0];
  const text = await resp.text();
  let payload = {};
  try {
    payload = text.trim() ? JSON.parse(text) : {};
  } catch {
    payload = { raw: text };
  }
  return { status: resp.status, payload };
}

(async () => {
  // 1. Setup status
  const st = await call("GET", "/ghost/api/admin/authentication/setup/");
  if (st.status !== 200) fail(`could not read setup status (HTTP ${st.status}): ${JSON.stringify(st.payload)}`);
  const done = Boolean(st.payload.setup?.[0]?.status);

  // 2. First-run setup if needed
  if (!done) {
    console.error(`Setting up Ghost admin ${EMAIL} ...`);
    const s = await call("POST", "/ghost/api/admin/authentication/setup/", {
      setup: [{ name: NAME, email: EMAIL, password: PASSWORD, blogTitle: TITLE }],
    });
    if (s.status !== 201) fail(`setup failed (HTTP ${s.status}): ${JSON.stringify(s.payload)}`);
  } else {
    console.error(`Ghost already set up; logging in as ${EMAIL} ...`);
  }

  // 3. Session login (sets the cookie via call())
  const login = await call("POST", "/ghost/api/admin/session/", {
    username: EMAIL,
    password: PASSWORD,
  });
  if (![200, 201].includes(login.status)) fail(`login failed (HTTP ${login.status}): ${JSON.stringify(login.payload)}`);

  // 4. Find-or-create the Custom Integration
  const list = await call("GET", "/ghost/api/admin/integrations/");
  if (list.status !== 200) fail(`could not list integrations (HTTP ${list.status}): ${JSON.stringify(list.payload)}`);
  let integration = (list.payload.integrations || []).find((i) => i.name === INTEGRATION);
  if (integration) {
    console.error(`Reusing existing integration: ${INTEGRATION}`);
  } else {
    console.error(`Creating integration: ${INTEGRATION}`);
    const c = await call("POST", "/ghost/api/admin/integrations/", {
      integrations: [{ name: INTEGRATION }],
    });
    if (c.status !== 201) fail(`integration create failed (HTTP ${c.status}): ${JSON.stringify(c.payload)}`);
    integration = c.payload.integrations[0];
  }

  // 5. Emit the content key
  const key = (integration.api_keys || []).find((k) => k.type === "content");
  if (!key) fail("integration has no content API key (Ghost schema change?)");
  console.log(`GHOST_CONTENT_KEY=${key.secret}`);
})().catch((e) => fail(e?.message || String(e)));
