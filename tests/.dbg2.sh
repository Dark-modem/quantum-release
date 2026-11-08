#!/usr/bin/env bash
A=/var/tmp/eng45-art
D=/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08
ls -la $A 2>/dev/null | grep -E "rathole|gost|chisel" | head -4
command -v unzip || echo "NO-UNZIP"
for f in $D/../.log-*; do :; done
# re-download one of each and inspect
cd $A
curl -fsSL --retry 1 -o rathole-test.zip "https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-x86_64-unknown-linux-gnu.zip" && echo "rathole ok $(stat -c%s rathole-test.zip)" || echo "rathole 404"
curl -fsSL --retry 1 -o gost-test.tgz "https://github.com/go-gost/gost/releases/download/v3.3.3/gost_3.3.3_linux_amd64.tar.gz" && echo "gost ok $(stat -c%s gost-test.tgz)" && tar -tzf gost-test.tgz | head -3 || echo "gost 404"
curl -fsSL --retry 1 -o chisel-test.gz "https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz" && echo "chisel ok $(stat -c%s chisel-test.gz)" || echo "chisel 404"
