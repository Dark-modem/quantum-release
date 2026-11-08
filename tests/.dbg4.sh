#!/usr/bin/env bash
cd /tmp && rm -rf dbg4 && mkdir dbg4 && cd dbg4
curl -fsSL -o bh.tgz "https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_amd64.tar.gz" && echo "bh $(stat -c%s bh.tgz)" && tar -tzf bh.tgz | head -3
curl -fsSL -o ra.zip "https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-x86_64-unknown-linux-gnu.zip" && echo "ra $(stat -c%s ra.zip)" && (unzip -o -q ra.zip && ls -la rathole 2>/dev/null || ls)
curl -fsSL -o go.tgz "https://github.com/go-gost/gost/releases/download/v3.3.3/gost_3.3.3_linux_amd64.tar.gz" && echo "go $(stat -c%s go.tgz)" && tar -tzf go.tgz | head -3
