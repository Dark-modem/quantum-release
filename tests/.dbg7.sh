#!/usr/bin/env bash
cd /tmp && rm -rf dbg7 && mkdir dbg7 && cd dbg7
curl -fsSL --retry 3 -o backhaul-0.7.2-amd64.tgz "https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_amd64.tar.gz"
echo "size: $(stat -c%s backhaul-0.7.2-amd64.tgz)"
head -c 4 backhaul-0.7.2-amd64.tgz | od -A n -t x1
tar -tzf backhaul-0.7.2-amd64.tgz | head -3
tar -xzf backhaul-0.7.2-amd64.tgz && echo EXTRACT-OK
