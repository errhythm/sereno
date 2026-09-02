// Sereno's OAuth relay.
//
// Slack will not distribute an app whose OAuth redirect URI is not HTTPS, and a Mac app's
// real callback is a loopback server on the user's own machine. So Slack sends the browser
// here, and this hands it back to the app.
//
// Why a page and not a bare 302: a redirect from HTTPS to http://127.0.0.1 is the standard
// desktop OAuth pattern, but a browser or an extension can refuse it, and a refused 302
// fails as an unexplained error page with the user stranded. This renders the hand-off
// instead, jumps immediately when it can, and shows the link to click when it cannot.
//
// Why this is not an open redirect: the destination is the constant below. Nothing in the
// request can influence where a visitor is sent. Only Slack's own callback parameters are
// forwarded, and only when the request looks like a callback at all.
//
// What this costs: the authorization code passes through Cloudflare instead of going
// straight to loopback. Under PKCE that code is useless on its own, because redeeming it
// needs the code_verifier, which is generated on the Mac and never leaves it. That is the
// whole reason PKCE exists, and it is what makes this relay acceptable rather than a
// downgrade.

// IPv4 literal on purpose. The app's listener binds `.ipv4(.loopback)`, and on macOS
// `localhost` can resolve to ::1 first, which would arrive at nothing.
const APP_CALLBACK = "http://127.0.0.1:47823/callback";

// Exactly what the app's own callback parser reads. Anything else Slack appends is dropped
// rather than forwarded blind.
const FORWARDED = ["code", "state", "error", "error_description"];

/// Every value below reaches this page from the query string, so anyone can put anything in
/// it. URLSearchParams already percent-encodes the dangerous characters, and this escapes
/// them again for the HTML contexts. Two layers on purpose: the page carries an auth code.
const escapeHtml = (s) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");

function handoffPage(target, nonce) {
  const href = escapeHtml(target);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connecting Sereno</title>
<link rel="stylesheet" href="/style.css">
<script nonce="${nonce}">location.replace(${JSON.stringify(target)});</script>
<noscript><meta http-equiv="refresh" content="0;url=${href}"></noscript>
</head>
<body>
<main>
  <nav><a href="/">sereno</a> / connecting</nav>

  <h1>Handing you back to Sereno.</h1>

  <p>Slack approved the connection. This page passes it to the app on your Mac, which is
  listening on port 47823.</p>

  <p>If you are still reading this, your browser declined to jump to a local address. Open
  the link yourself:</p>

  <p><a class="handoff" href="${href}">${href}</a></p>

  <p class="note">Sereno has to still be running and waiting. If you quit it, or left this
  page sitting for a few minutes, start again from Sereno's Settings.</p>
</main>
</body>
</html>
`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname !== "/callback") {
      return env.ASSETS.fetch(request);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    // A real callback carries either a code or an error. Without one this is somebody
    // poking the endpoint, and they do not get pointed at their own machine for it.
    if (!url.searchParams.has("code") && !url.searchParams.has("error")) {
      return new Response("Not a Slack callback.", {
        status: 400,
        headers: { "Cache-Control": "no-store" },
      });
    }

    const forward = new URLSearchParams();
    for (const key of FORWARDED) {
      const value = url.searchParams.get(key);
      if (value !== null) forward.set(key, value);
    }
    const target = `${APP_CALLBACK}?${forward}`;

    // A nonce rather than 'unsafe-inline': the one script here is ours, and an injected one
    // still cannot run even if the escaping above were wrong.
    const nonce = crypto.randomUUID();

    return new Response(handoffPage(target, nonce), {
      status: 200,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        // An authorization code must not sit in any cache, here or in between.
        "Cache-Control": "no-store",
        // Keeps the code out of a Referer header on the next hop.
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": [
          "default-src 'none'",
          `script-src 'nonce-${nonce}'`,
          "style-src 'self'",
          "base-uri 'none'",
          "frame-ancestors 'none'",
        ].join("; "),
      },
    });
  },
};
