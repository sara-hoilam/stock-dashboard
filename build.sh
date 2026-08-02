#!/usr/bin/env bash
# Build the static site for Cloudflare Pages.
#
# Pages settings:
#   Build command:        bash build.sh
#   Build output directory: public
#
# There is no bundler and nothing to install — the dashboard is one file. All
# this does is put it where Pages expects it, next to the committed config.js
# that points the page at Supabase.
set -euo pipefail

mkdir -p public
cp dashboard.html public/index.html

if [ ! -f public/config.js ]; then
  echo "public/config.js is missing — the page would fall back to a local" >&2
  echo "server that does not exist in production." >&2
  exit 1
fi

echo "built public/: $(ls -1 public | tr '\n' ' ')"
