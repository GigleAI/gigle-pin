#!/usr/bin/env bash
# The instructions for AI agents have a single source: .agents/skills/pin-screen-recorder/. Run this
# after editing them.
#
#   Resources/pin-screen-recorder/   ships inside the app (XcodeGen does not accept a folder
#                                    reference to a dot-directory like .agents)
#   the website's skill/             the raw file, a .tgz, and the page with SKILL.md **inlined**
#                                    statically — what an agent fetches with curl has to be usable,
#                                    and loading it with JS would return nothing but "loading…"
#
# The website copy is **not part of the open-source subset**, so its path is not hardcoded here
# (hardcoding it would point a public file at a directory that does not exist on that side). Sync it
# if it is there, skip it if it is not — one script that runs correctly in either repo.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=.agents/skills/pin-screen-recorder
SITE="${PIN_SITE_DIR:-$(ls -d ./*/site/skill 2>/dev/null | head -1)}"

rm -rf Resources/pin-screen-recorder && cp -R "$SRC" Resources/pin-screen-recorder
echo "  bundled copy synced → Resources/pin-screen-recorder/"

if [ -d "$SITE" ]; then
  cp "$SRC/SKILL.md" "$SITE/SKILL.md"
  tar czf "$SITE/pin-screen-recorder.tgz" -C .agents/skills pin-screen-recorder
  SITE="$SITE" python3 - <<'PY'
import html, os, pathlib, re
page = pathlib.Path(os.environ['SITE']) / 'index.html'
if page.exists():
    t = page.read_text()
    body = html.escape(pathlib.Path('.agents/skills/pin-screen-recorder/SKILL.md').read_text())
    t = re.sub(r'<pre id="skill">.*?</pre>', '<pre id="skill">' + body + '</pre>', t, flags=re.S)
    t = re.sub(r'<script>\s*fetch\(.SKILL\.md.\).*?</script>\s*', '', t, flags=re.S)
    page.write_text(t)
PY
    echo "  website copy synced → $SITE/"
else
    echo "  (no $SITE, skipping the website copy — the open-source repo does not have one)"
fi
