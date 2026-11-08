#!/usr/bin/env bash
# Offline pack test for the phase-7 engines: fake wstunnel (tar.gz with
# dir entry) + fake chisel (FLAT .gz) upstreams → both must produce the
# signed, agent-shaped artifacts with LICENSE + SOURCE.txt.
set -euo pipefail
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release
FAKE=/tmp/pack45; rm -rf "$FAKE"; mkdir -p "$FAKE/up/wstunnel_10.1.9"

printf '#!/bin/sh\necho fake-wst\n' > "$FAKE/up/wstunnel_10.1.9/wstunnel"
chmod 755 "$FAKE/up/wstunnel_10.1.9/wstunnel"
echo "fake BSD-3 license" > "$FAKE/up/wstunnel_10.1.9/LICENSE"
( cd "$FAKE/up" && tar -czf "$FAKE/wstunnel_10.1.9_linux_amd64.tar.gz" wstunnel_10.1.9 )
( cd "$FAKE/up" && tar -czf "$FAKE/wstunnel_10.1.9_linux_arm64.tar.gz" wstunnel_10.1.9 )

printf '#!/bin/sh\necho fake-chisel\n' > "$FAKE/chisel_bin"
chmod 755 "$FAKE/chisel_bin"
gunzip -kf "$FAKE/chisel_bin" 2>/dev/null || true
gzip -kf "$FAKE/chisel_bin"
mv "$FAKE/chisel_bin.gz" "$FAKE/chisel_1.10.1_linux_amd64.gz"
cp "$FAKE/chisel_1.10.1_linux_amd64.gz" "$FAKE/chisel_1.10.1_linux_arm64.gz"

export HOME=/tmp/pack45-home; rm -rf "$HOME"; mkdir -p "$HOME"
ENGINE_CONF="$(pwd)/engines/wstunnel.conf" bash scripts/pack-engine.sh wstunnel v10.1.9 --from "$FAKE" --out "$FAKE/out" > /dev/null
ENGINE_CONF="$(pwd)/engines/chisel.conf" bash scripts/pack-engine.sh chisel v1.10.1 --from "$FAKE" --out "$FAKE/out" > /dev/null

for f in wstunnel-v10.1.9-linux-amd64.tar.gz chisel-v1.10.1-linux-amd64.tar.gz; do
    echo "== $f shape =="
    tar -tzf "$FAKE/out/$f" | head -5
    ( cd "$FAKE/out" && sha256sum -c "$f.sha256" )
    base64 -d "$FAKE/out/$f.sig.b64" > /tmp/p45.sig
    openssl pkey -in /tmp/pack45-home/.quantum-release/engine-signing.key -pubout -out /tmp/p45.pub
    openssl pkeyutl -verify -rawin -pubin -inkey /tmp/p45.pub -in "$FAKE/out/$f" -sigfile /tmp/p45.sig
done
echo "wstunnel SOURCE.txt:"; tar -xzOf "$FAKE/out/wstunnel-v10.1.9-linux-amd64.tar.gz" wstunnel_10.1.9/SOURCE.txt | head -3
echo "chisel SOURCE.txt:"; tar -xzOf "$FAKE/out/chisel-v1.10.1-linux-amd64.tar.gz" chisel_1.10.1/SOURCE.txt | head -3
rm -rf "$FAKE" /tmp/p45.sig /tmp/p45.pub /tmp/pack45-home
echo "PACK45-OFFLINE-TEST: PASS"
