#!/usr/bin/env bash
for n in backhaul_linux_amd64.tar.gz backhaul-amd64-linux.tar.gz backhaul_0.7.2_linux_amd64.tar.gz Backhaul_linux_amd64.tar.gz backhaul-v0.7.2-linux-amd64.tar.gz; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -L "https://github.com/TheChickenLove/Backhaul/releases/download/v0.7.2/$n")
    echo "$n -> $code"
done
curl -fsSL "https://api.github.com/repos/TheChickenLove/Backhaul/releases/tags/v0.7.2" 2>/dev/null | grep -oE '"name": "[^"]+\.(tar|zip|gz)[^"]*"' | head -6
