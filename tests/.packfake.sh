#!/usr/bin/env bash
# Offline test of pack-engine.sh against a FAKE upstream (phase 6 T4).
set -euo pipefail
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release

FAKE=/tmp/packfake; rm -rf "$FAKE"; mkdir -p "$FAKE/up/frp_9.9.9"
printf '#!/bin/sh\necho fake-frps\n' > "$FAKE/up/frp_9.9.9/frps"
printf '#!/bin/sh\necho fake-frpc\n' > "$FAKE/up/frp_9.9.9/frpc"
chmod 755 "$FAKE/up/frp_9.9.9/frps" "$FAKE/up/frp_9.9.9/frpc"
echo "fake Apache-2.0 license text" > "$FAKE/up/frp_9.9.9/LICENSE"
( cd "$FAKE/up" && tar -czf "$FAKE/frp_9.9.9_linux_amd64.tar.gz" frp_9.9.9 )
( cd "$FAKE/up" && tar -czf "$FAKE/frp_9.9.9_linux_arm64.tar.gz" frp_9.9.9 )
printf '%s  frp_9.9.9_linux_amd64.tar.gz\n' "$(sha256sum "$FAKE/frp_9.9.9_linux_amd64.tar.gz" | cut -d" " -f1)" > "$FAKE/checksums.txt"

export HOME=/tmp/packfake-home; rm -rf "$HOME"; mkdir -p "$HOME"
ENGINE_CONF="$(pwd)/engines/frp.conf" bash scripts/pack-engine.sh frp v9.9.9 --from "$FAKE" --out "$FAKE/out" 2>&1 | tail -12

P="$FAKE/out/frp-v9.9.9-pack"
echo "== shape =="
tar -tzf "$P/frp-v9.9.9-linux-amd64.tar.gz" | head -6
echo "== sha256 sidecar =="
( cd "$P" && sha256sum -c frp-v9.9.9-linux-amd64.tar.gz.sha256 )
echo "== signature =="
base64 -d "$P/frp-v9.9.9-linux-amd64.tar.gz.sig.b64" > /tmp/pf.sig
openssl pkey -in /tmp/packfake-home/.quantum-release/engine-signing.key -pubout -out /tmp/pf.pub
openssl pkeyutl -verify -rawin -pubin -inkey /tmp/pf.pub -in "$P/frp-v9.9.9-linux-amd64.tar.gz" -sigfile /tmp/pf.sig
echo "== SOURCE.txt =="
tar -xzOf "$P/frp-v9.9.9-linux-amd64.tar.gz" frp_9.9.9/SOURCE.txt | head -4
echo "== LICENSE =="
tar -xzOf "$P/frp-v9.9.9-linux-amd64.tar.gz" frp_9.9.9/LICENSE | head -1
echo "== upload commands =="
grep -c "api/mesh/engines/artifacts" "$P/UPLOAD-COMMANDS.txt"
rm -rf "$FAKE" /tmp/pf.sig /tmp/pf.pub /tmp/packfake-home
echo "PACK-OFFLINE-TEST: PASS"
