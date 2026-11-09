#!/usr/bin/env bash
# rc5 --verify-only in a quantum-test-* container (docker.exe from Git
# Bash; WSL docker integration may be down), removed with proof.
set -uo pipefail
DOCKER="docker"; command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
$DOCKER info >/dev/null 2>&1 || { echo "SKIP: docker unreachable"; exit 0; }
CT="quantum-test-rc5verify"
$DOCKER rm -f "$CT" >/dev/null 2>&1 || true
DIST='C:/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist'
$DOCKER run -d --name "$CT" -v "${DIST}:/dist:ro" ubuntu:24.04 sleep 600 >/dev/null
$DOCKER exec "$CT" bash -c "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq openssl curl >/dev/null 2>&1; echo deps-ok"
PANEL_ARM=$(awk '$2=="quantum-panel-linux-arm64"{print $1}' "$DIST/quantum-bundle-v0.3.4-rc6/bin/checksums.txt")
AGENT_AMD=$(awk '$2=="quantum-agent-linux-amd64"{print $1}' "$DIST/quantum-bundle-v0.3.4-rc6/bin/checksums.txt")
RC=0
echo "== --verify-only panel (arm64) =="
$DOCKER exec "$CT" bash -c "cd /dist/quantum-bundle-v0.3.4-rc6 && bash install-panel.sh --verify-only --binary bin/quantum-panel-linux-arm64 --checksum $PANEL_ARM" 2>&1 | tail -2 || RC=1
echo "== --verify-only agent (amd64) =="
$DOCKER exec "$CT" bash -c "cd /dist/quantum-bundle-v0.3.4-rc6 && bash install-agent.sh --verify-only --binary bin/quantum-agent-linux-amd64 --checksum $AGENT_AMD" 2>&1 | tail -2 || RC=1
echo "== checksums.txt signature inside the container =="
$DOCKER exec "$CT" bash -c "cd /dist/quantum-bundle-v0.3.4-rc6 && openssl pkeyutl -verify -rawin -pubin -inkey signing-public.pem -in bin/checksums.txt -sigfile bin/checksums.txt.sig" 2>&1 | tail -1 || RC=1
$DOCKER rm -f "$CT" >/dev/null 2>&1
echo "== proof: container removed =="
$DOCKER ps -a --format '{{.Names}}' | grep -x "$CT" && echo "LEFTOVER!" || echo "$CT: none ✓"
exit $RC
