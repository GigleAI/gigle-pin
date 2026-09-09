# Contributing

The point of open-sourcing this is that you can take it apart and build the
version you actually want — with an AI or by hand. Forks are a fine outcome.
Pull requests are welcome too.

## Before you start

Read [`AGENTS.md`](AGENTS.md) for the rules that keep the codebase coherent, and
[`docs/lessons.md`](docs/lessons.md) for the mistakes that already cost someone a
day. Both are short.

## Setting up

```bash
brew install xcodegen
xcodegen generate
scripts/build.sh
```

macOS will ask for **Screen Recording** permission on first launch. Accessibility
is optional and unlocks control-level window snapping plus drawing while
recording.

`project.yml` carries our Apple Development team, which you are not in. Change
`DEVELOPMENT_TEAM` to your own team ID (or pick your team in Xcode's Signing &
Capabilities) before building. Keep automatic signing rather than switching to
ad-hoc: macOS ties Screen Recording permission to the signing identity, and an
ad-hoc build gets a new identity on every compile — meaning you re-grant the
permission every single time.

If you plan to distribute your build to other people, also change the bundle
identifier and URL scheme (see [`AGENTS.md`](AGENTS.md)) — two apps sharing
`ai.gigle.pin` on one Mac will quietly break each other's permissions and
settings. And note that a build you hand someone else is not notarized, so
macOS will refuse to open it until they clear it in System Settings ▸ Privacy &
Security.

## Sending a change

- Keep it to one thing. A change that fixes a bug and renames six files is two
  changes.
- Run `scripts/build.sh` and `scripts/smoke.sh`.
- If you touched recording, annotation burn-in, or GIF export, say how you
  verified it. Those three have all shipped bugs that looked fine on screen.
- New user-facing strings use `L("key", "中文原文")`; run `scripts/i18n-scan.sh`
  and fill in the English.
- Explain *why* in the commit message. What changed is in the diff.

## Reporting a bug

Include your macOS version, whether the app is the App Store build or built from
source, and what you expected instead. For anything involving recording, the
resulting file is usually worth more than a description of it.

## Scope

Things this project is unlikely to take: third-party dependencies, an Electron or
web view anywhere, cloud accounts, telemetry.
