#!/usr/bin/env bash
# Build the static site for Cloudflare Pages.
#
# Pages settings:
#   Build command:          bash build.sh
#   Build output directory: public
#
# Two pages, no bundler:
#   index.html    Markets Today — the landing page
#   company.html  the filed-financials dashboard
set -euo pipefail

mkdir -p public
cp landing.html   public/index.html
cp dashboard.html public/company.html

if [ ! -f public/config.js ]; then
  echo "public/config.js is missing — both pages would have no data source." >&2
  exit 1
fi

echo "built public/: $(ls -1 public | tr '\n' ' ')"
