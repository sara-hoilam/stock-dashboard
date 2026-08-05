#!/usr/bin/env bash
# Build the static site for Cloudflare Pages.
#
# Pages settings:
#   Build command:          bash build.sh
#   Build output directory: public
#
# Three pages plus the shared navigation, no bundler:
#   index.html    Markets Today — the landing page
#   news.html     market news
#   company.html  the filed-financials dashboard
#   nav.js/.css   the top bar every page injects
#   clarity-init.js + vendor/clarity  Microsoft Clarity (@microsoft/clarity)
set -euo pipefail

# Clarity ships as an npm package; install it when the build environment does
# not already have node_modules (Cloudflare Pages, a fresh clone).
if [ ! -f node_modules/@microsoft/clarity/index.js ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --omit=dev
  else
    echo "npm is required to install @microsoft/clarity" >&2
    exit 1
  fi
fi

mkdir -p public/vendor/clarity/src
cp landing.html   public/index.html
cp dashboard.html public/company.html
cp news.html      public/news.html
cp nav.js nav.css public/
cp clarity-init.js public/
cp node_modules/@microsoft/clarity/index.js      public/vendor/clarity/
cp node_modules/@microsoft/clarity/package.json  public/vendor/clarity/
cp node_modules/@microsoft/clarity/src/utils.js  public/vendor/clarity/src/

if [ ! -f public/config.js ]; then
  echo "public/config.js is missing — both pages would have no data source." >&2
  exit 1
fi

# Optional: inject Clarity project ID from the environment (Cloudflare Pages
# env var, or a local `.env` already exported). Leaves config.js unchanged
# when unset so a committed ID keeps working.
if [ -n "${CLARITY_PROJECT_ID:-}" ]; then
  python3 - "$CLARITY_PROJECT_ID" <<'PY'
import json, pathlib, re, sys
pid, path = sys.argv[1], pathlib.Path("public/config.js")
text = path.read_text(encoding="utf-8")
new, n = re.subn(
    r'clarityProjectId:\s*["\'][^"\']*["\']',
    "clarityProjectId: " + json.dumps(pid),
    text, count=1)
if n != 1:
    sys.exit("could not inject CLARITY_PROJECT_ID into public/config.js")
path.write_text(new, encoding="utf-8")
print(f"clarity: injected project id ({len(pid)} chars)")
PY
fi

echo "built public/: $(ls -1 public | tr '\n' ' ')"
