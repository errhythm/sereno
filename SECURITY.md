# Security policy

Sereno is a macOS menu bar app that reads your Slack messages on your own machine and ranks
the ones you owe a reply to. It has no server, so the interesting attack surface is small and
specific. That is what this policy covers.

## Reporting a vulnerability

Email **info@rhystart.com**. Please do not open a public GitHub issue for a security problem.

Include what you need to make the problem clear: what you did, what happened, the macOS
version, and the Sereno version. A proof of concept helps. If you would like a reply
encrypted, say so and we will arrange a key.

What to expect:

- Acknowledgement within **5 working days**.
- An assessment, and a fix or an explanation of why it is not a vulnerability, within **30
  days** of acknowledgement.
- Credit in the release notes if you want it, or none if you would rather stay anonymous.

Please allow **90 days** before disclosing publicly, or less if a fix ships sooner. If 90 days
pass with no fix and no explanation, publish; that is a fair outcome and not a breach of this
policy.

RhyStart Technologies is a small operation with no bug bounty programme, so there is no
payment. Reports are still genuinely welcome.

## In scope

- The OAuth flow: the PKCE exchange, the loopback listener on `127.0.0.1:47823`, and the
  redirect relay at `sereno.errhythm.me/callback`.
- Keychain handling of the Slack user token, service `com.rhystart.sereno`.
- The local state file at `~/Library/Application Support/Sereno/state.json`, and anything that
  could cause message content to be written to disk or to a log.
- Anything that would let message text reach the network, other than back to Slack itself.
- The `docs/` site and the Cloudflare Worker that serves it.

## Out of scope

- Anything requiring an attacker who already has local code execution or admin rights on the
  user's Mac. A local attacker with those powers can read the Keychain regardless of what this
  app does.
- Slack's own API, infrastructure or rate limits. Report those to Slack.
- Apple's on-device foundation model. Report those to Apple.
- Missing hardening on the static site that has no security consequence, such as a report-only
  header on pages that carry no user data.
- Social engineering, physical access, and denial of service against the marketing site.

## Design decisions that are deliberate, not bugs

Please read these before reporting them, because each one is a considered trade-off and it is
written down here so a report can argue with the reasoning rather than the symptom.

**The app ships no client secret.** The OAuth flow is PKCE precisely because anything embedded
in a distributed Mac binary is extractable. A missing `client_secret` is correct here, not an
oversight.

**The authorization code passes through Cloudflare.** Slack will not distribute an app whose
redirect URI is not HTTPS, while a Mac app's real callback is a loopback listener. So the
browser lands on `sereno.errhythm.me/callback`, which hands off to `127.0.0.1:47823`. The code
is never stored, never logged and never cached, and under PKCE it cannot be redeemed without
the `code_verifier`, which is generated on the Mac and never leaves it. No access token ever
passes through the relay.

**The relay is not an open redirect.** Its destination is a compile-time constant. Nothing in
the request can influence where a visitor is sent, and only Slack's own callback parameters are
forwarded.

**The listener binds port 47823 on IPv4 loopback only.** The port is below the macOS ephemeral
range floor so the OS cannot hand it to something else, and it is never exposed off the
machine.

**The token lives only in the Keychain.** It is not written to a file, a preference or a log.
If you find a path where it reaches any of those, that is a real bug and worth reporting.

**Message text is read on the device and not persisted.** What is saved is the derived task,
its priority and a Slack permalink. A path that writes raw message content to disk or to the
unified log is a real bug. Note that `error.localizedDescription` from the on-device model has
previously leaked prompt content into logs, which is why those interpolations are marked
private; a regression there is in scope.
