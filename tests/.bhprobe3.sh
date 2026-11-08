#!/usr/bin/env bash
for repo in TheChickenLove/Backhaul Musixal/backhaul; do
  for tag in v0.7.2 0.7.2; do
    out=$(curl -sL "https://github.com/$repo/releases/expanded_assets/$tag" | grep -oE '/[A-Za-z0-9_.-]+/releases/download/[^"]+' | head -4)
    [ -n "$out" ] && { echo "== $repo @$tag"; echo "$out"; }
  done
done
