#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/go/bin
D=/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/quantum-bundle-v0.3.4-rc6
cd $D/bin
echo "== 1. checksums =="
sha256sum -c checksums.txt 2>&1 | head -6
echo "== 2. signatures =="
openssl pkeyutl -verify -rawin -pubin -inkey ../signing-public.pem -in checksums.txt -sigfile checksums.txt.sig | head -1
for f in quantum-panel-linux-amd64 quantum-agent-linux-amd64 quantum-panel-linux-arm64 quantum-agent-linux-arm64; do
  openssl pkeyutl -verify -rawin -pubin -inkey ../signing-public.pem -in $f -sigfile $f.sig | head -1 | sed "s/^/$f: /"
done
echo "== 3. pin: panel binary carries the phase-10 UI + version =="
strings quantum-panel-linux-amd64 | grep -c "quantum-mesh.css" | xargs echo "quantum-mesh.css refs:"
strings quantum-panel-linux-amd64 | grep -c "v0.3.3-rc5" || true
strings quantum-panel-linux-amd64 | grep -c "mesh-first" | xargs echo "mesh-first strings:"
echo "== 4. agent pins the engine key =="
PUB=$(cat engine-pub.b64)
strings quantum-agent-linux-amd64 | grep -c "$PUB" | xargs echo "agent pins engine-pub:"
echo "== 5. SHAs built from =="
grep "Panel SHA\|Agent SHA" ../README.txt
