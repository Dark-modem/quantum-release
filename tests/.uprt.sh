#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/go/bin
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-panel
CGO_ENABLED=0 go build -o /tmp/qp-rt ./cmd/quantum-panel
rm -rf /tmp/qp-rt-cfg && mkdir -p /tmp/qp-rt-cfg/engine-artifacts
printf '{"base_path":"rt","port":18797}' > /tmp/qp-rt-cfg/panel.json
# The panel's engine-pub = the packer's key (same ceremony as production).
cp /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08/frp-0.61.1-pack/ENGINE-PUB-KEY.txt /tmp/pk.txt
tail -1 /tmp/pk.txt > /tmp/qp-rt-cfg/engine-artifacts/engine-pub.b64
GRE_PANEL_DIR=/tmp/qp-rt-cfg /tmp/qp-rt password rt-pass-123 >/dev/null 2>&1
GRE_PANEL_DIR=/tmp/qp-rt-cfg /tmp/qp-rt > /tmp/qp-rt.log 2>&1 &
PID=$!
sleep 2
PANEL_URL="http://127.0.0.1:18797/rt"
CJ=/tmp/rt-cj; PASSF=/tmp/rt-pass; USERF=/tmp/rt-user
printf 'rt-pass-123\n' > "$PASSF"; printf 'admin\n' > "$USERF"
export PANEL_URL
export PANEL_URL PANEL_PASS_FILE="$PASSF" PANEL_USER_FILE="$USERF"
bash /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08/upload-all.sh 2>&1 | grep -c '"status":"stored"' || true
echo "== manifest =="
curl -s "$PANEL_URL/api/agent/engine-artifacts" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['artifacts']), 'artifacts in manifest'); [print(a['engine'], a['version'], a['goarch']) for a in d['artifacts']]"
kill $PID 2>/dev/null || true
rm -rf /tmp/qp-rt /tmp/qp-rt-cfg /tmp/qp-rt.log /tmp/rt-cj /tmp/rt-pass /tmp/rt-user /tmp/pk.txt
echo "UPLOAD-ROUND-TRIP: DONE"
