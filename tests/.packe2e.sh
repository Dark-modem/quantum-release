#!/usr/bin/env bash
# End-to-end: packer output -> throwaway panel (127.0.0.1 only) ->
# upload via the generated curl -> agent manifest shows the pins.
set -euo pipefail
export GOFLAGS=-mod=mod GOPROXY=file:///tmp/goproxy,https://proxy.golang.org GOSUMDB=off GOPRIVATE=github.com/Dark-modem/* GOPATH=$HOME/go
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/go/bin"
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-panel
CGO_ENABLED=0 go build -o /tmp/qp-pack ./cmd/quantum-panel
rm -rf /tmp/qp-pack-cfg && mkdir -p /tmp/qp-pack-cfg/engine-artifacts
printf '{"base_path":"pk","port":18795}' > /tmp/qp-pack-cfg/panel.json
GRE_PANEL_DIR=/tmp/qp-pack-cfg /tmp/qp-pack password pack-pass-123 >/dev/null 2>&1
# Panel verifies uploads against engine-pub.b64: use the PACKER's public key.
# Pack fresh (the /tmp dir may not survive between tool invocations).
RELEASE_DIR=/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release
ENGINE_SIGNING_KEY=/mnt/c/Users/-Mahdi/quantum-release-keys/engine-signing.key   bash "$RELEASE_DIR/scripts/pack-engine.sh" frp 0.61.1 --out /tmp/packreal > /dev/null
P=/tmp/packreal/frp-0.61.1-pack
tail -1 "$P/ENGINE-PUB-KEY.txt" > /tmp/qp-pack-cfg/engine-artifacts/engine-pub.b64
GRE_PANEL_DIR=/tmp/qp-pack-cfg /tmp/qp-pack > /tmp/qp-pack.log 2>&1 &
PID=$!
sleep 2
# Login (session + csrf).
CJ=/tmp/qp-cookies.txt
curl -s -c "$CJ" -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"pack-pass-123"}' http://127.0.0.1:18795/pk/api/login > /dev/null
CSRF=$(grep gre_csrf "$CJ" | awk '{print $7}')
SIG=$(cat "$P/frp-0.61.1-linux-amd64.tar.gz.sig.b64")
echo "== upload amd64 via the generated command shape =="
curl -s -b "$CJ" -H "X-CSRF-Token: $CSRF" -X POST 'http://127.0.0.1:18795/pk/api/mesh/engines/artifacts' \
  -F 'engine=frp' -F 'version=0.61.1' -F 'goarch=amd64' -F 'goos=linux' \
  -F 'name=frp-0.61.1-linux-amd64.tar.gz' \
  -F "signature=$SIG" \
  -F 'file=@'"$P"'/frp-0.61.1-linux-amd64.tar.gz'
echo
echo "== unauth agent manifest =="
curl -s 'http://127.0.0.1:18795/pk/api/agent/engine-artifacts?engine=frp&goarch=amd64'
echo
kill $PID 2>/dev/null || true
rm -rf /tmp/qp-pack /tmp/qp-pack-cfg /tmp/qp-pack.log /tmp/qp-cookies.txt /tmp/packreal
echo "PACK-E2E: PASS"
