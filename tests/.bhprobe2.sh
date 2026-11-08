#!/usr/bin/env bash
curl -fsSL "https://api.github.com/repos/TheChickenLove/Backhaul/releases" 2>/dev/null | head -c 100 || echo "api-unreachable"
echo
curl -s "https://github.com/TheChickenLove/Backhaul/releases/expanded_assets/v0.7.2" | grep -oE 'href="[^"]+"' | grep -iE "amd64|arm64" | head -6
