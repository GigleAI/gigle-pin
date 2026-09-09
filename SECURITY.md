# Security

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting: **Security → Report a vulnerability** on this
repository. It creates a private thread only the maintainers can see.

If that is unavailable, email **hello@gigle.ai** with `gigle-pin security` in the
subject. It reaches the same people; there is no personal address to find here.

Tell us what you can reproduce and how. A proof of concept helps; a working
exploit is not required. You will get a first reply within a few days, and we
will tell you what we found and when a fix ships. We will credit you in the
release notes unless you prefer otherwise.

## Supported versions

The latest release is the one that gets fixes. There are no long-term support
branches — Gigle Pin is a single small app, and the answer to "is my version
patched" should always be "update to the newest one".

## What Pin can reach

Useful context before deciding whether something is a bug:

- **Everything stays on the machine.** Pin has no server, no account, no
  telemetry and makes no network requests of its own. Captures go to the
  clipboard or to a folder the user chose.
- **Screen recording permission is required** for anything that reads pixels —
  screenshots included. macOS grants it to Pin, and macOS shows its own
  recording indicator whenever it is in use.
- **Accessibility permission is optional.** Without it Pin loses window-level
  snapping precision and drawing during a recording, and nothing else.
- The **Developer ID build from the website is not sandboxed**; the Mac App
  Store build is. Both are signed and notarized.

## The `pin://` interface, and its limits

Pin registers a URL scheme so an agent, a Shortcut or a script can drive it —
that is a headline feature, not an accident. It is worth being explicit about
what that does and does not protect:

`pin://` is the only scheme a released build answers to, and it is worth saying so explicitly:
until 0.1.8 the bundle also registered `jay://`, an alias from before the app was renamed, which
reached exactly the same code. Nothing used it — the first public release already spoke `pin://` —
so it was a second way in that no document mentioned and therefore nobody audited. It is gone.
(The Director build, which is not distributed, answers to `pindirector://` instead.)

**macOS does not tell an application who opened a URL.** The user's own agent, a
Shortcut, a shell script and a web page that navigated to `pin://…` are
indistinguishable by the time Pin sees the request. So Pin does not try to
authenticate the caller. It limits what any caller can reach:

- Output paths must be **absolute**, must be **inside** the user's Pictures,
  Movies, Downloads, Desktop, Documents, save folder or a temporary directory,
  and must carry the **extension the verb actually writes**. Symlinks and `..`
  are resolved before that check. `~/Library`, dotfile directories and the
  system tree are unreachable — the classes of write that turn into persistence
  or code execution.
- **An existing file is never replaced** unless the request says `overwrite=1`.
  This one is an anti-accident measure, not a boundary: a hostile URL can pass
  that flag as easily as any other. The boundary is the directory and extension
  confinement above.
- **Recording is never invisible.** Starting one always shows Pin's own red
  region frame and its HUD, on top of the recording indicator macOS puts in the
  menu bar regardless of what we do.
- Requests are validated before they are acted on: an unknown verb, a repeated
  parameter, a non-finite number or a non-positive size is refused with a reason
  in the log.

**What this means for a report.** "A local process can drive Pin through
`pin://`" is the documented design, so please include what a caller gains beyond
the limits above — writing outside the allowed roots, replacing a file without
`overwrite=1`, recording with no visible indicator, escaping via a symlink, or
crashing the app from a malformed URL. Those are bugs and we want to hear about
them.

The rules live in `Sources/Pin/Util/AgentRequest.swift`, which is the one place
that treats `pin://` input as untrusted — read it before reporting, and note that
each rule there is exercised against a real build by our release checks.

## Out of scope

- Anything requiring the attacker to already have code execution as the user, or
  physical access to an unlocked Mac.
- Reports from automated scanners with no demonstrated impact.
- Missing hardening that a released build does not actually need — tell us the
  consequence, not the checkbox.
