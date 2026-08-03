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
set -euo pipefail

mkdir -p public
cp landing.html   public/index.html
cp dashboard.html public/company.html
cp news.html      public/news.html
cp nav.js nav.css public/

if [ ! -f public/config.js ]; then
  echo "public/config.js is missing — both pages would have no data source." >&2
  exit 1
fi

echo "built public/: $(ls -1 public | tr '\n' ' ')"
