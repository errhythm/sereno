# Sereno

A macOS menu bar app that notices the Slack messages you owe a reply to, ranks them with the
on-device Apple Intelligence model, and puts you one click from the right message in Slack.

Named after the *serenos*, the night watchmen who walked Spanish cities from 1715 to the
1970s calling out the hour and the sky: *"Las dos y sereno"*, two o'clock and clear. It
watches while you are not looking, and tells you when there is nothing to worry about.

Sereno is a helper, not a replacement. It does not reply for you, and it never posts
anything. Slack keeps the conversation.

## Setup

1. **Turn on Apple Intelligence** in System Settings, Apple Intelligence and Siri. Ranking
   runs entirely on your Mac, so nothing about your messages leaves the machine. Without it
   the app still runs, and says so, but every task falls back to a generic "Reply to X".

2. **Connect Slack** in Settings. Sereno signs in with OAuth and PKCE, so there is no client
   secret in the app and the token lives in your Keychain. It asks for read-only scopes
   only: message history, conversation and user lists. Nothing that can post, react or
   delete.

3. **Fill in "Your role"** in Settings. One line, in your own words, for example "backend
   engineer, I own deployments and the public API". This is what lets the model judge whether
   an unaddressed channel message like "Team, please complete the deployment doc" is yours.
   It measurably changes the ranking.

4. Optionally set a city under Weather to have the header sky reflect real conditions. Off by
   default, and it sends only a place name to Open-Meteo.

## Build

```bash
bash build.sh          # produces Sereno.app, ad-hoc signed
open Sereno.app
```

Menu bar only, no Dock icon. **Cmd+Shift+T** toggles the panel from anywhere,
**Cmd+Shift+O** opens it as a movable window, **Cmd+N** adds a task by hand, **Cmd+,** opens
Settings.

Diagnostics go to the unified log. Note `log` is a zsh builtin, so use the full path:

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "com.rhystart.sereno"' --style compact
```

## How it decides something is yours

Deterministically, in Swift, never by asking the model. A message counts if it is a DM,
@-mentions you, replies to something you wrote, lands in a thread you posted in, mentions a
user group you belong to, or names you in plain text. `@channel` and `@here` do not count by
default, because they are addressed to a room rather than to you. Both the name-matching and
broadcast rules can be switched off in Settings; DMs, mentions and replies to you cannot,
because those are never ambiguous.

A message with no signal at all is not discarded. It is handed to the model to judge against
your role, which is how "Team, please..." survives.

## How ranking works

A conversation, not a message, is the unit. If someone says "Hi" and then "make sure to
review it within the hour", that stays one task and escalates to urgent rather than becoming
two. Two genuinely separate asks in one conversation do become two tasks.

Priorities are Now, Today and Later. You can override any of them, and your override wins
over the model. Items you reply to in Slack clear themselves on the next check.

## Limitations, stated plainly

- **The Slack client is not built yet.** The app currently runs on 17 fixture messages from
  `MockMessageSource`, so what you see is realistic but not yours. Sign-in exists; the fetch
  behind it does not.
- Reply detection means "you posted in that conversation after the last inbound message". In
  a DM that is accurate. In a busy channel it will occasionally clear something you did not
  actually answer.
- Manual tasks you type have no Slack message behind them, so they never auto-complete and
  have nothing to open.
- Weather needs a city typed in Settings. There is no location permission prompt by design.
