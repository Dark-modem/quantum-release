#!/usr/bin/env bash
# tests/installer_lifecycle_test.sh — phase-14 TASK 2: the bundle's
# installers are exercised in a clean ubuntu:24.04 container
# (quantum-test-installers-lc), as far as a systemd-free container allows:
#
#   A. agent --uninstall removes ONLY Quantum-owned files (unit, sysctl
#      drop-ins, journald drop-in, binaries); config/state KEPT; foreign
#      software (a fake Pasarguard node + third-party sysctl file) untouched.
#   B. agent --purge additionally removes the config/state dirs.
#   C. agent --upgrade swaps the binary, KEEPS config, hash-verifies the
#      installed binary (RUNBOOK-FIXES 31); with a fake systemctl that never
#      reports active, the upgrade ROLLS BACK to the previous binary.
#   D. panel --upgrade keeps config and rolls back the same way.
#
# BACKEND-27: parameterized — the rc6 zip path + fixed container name were
# hardcoded; the bundle top dir is now derived from the zip itself.
# Usage: installer_lifecycle_test.sh [bundle-zip]   (default: the rc6 zip)
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CT="${LIFECYCLE_CT:-quantum-test-installers-lc}"
ZIP="${1:-$PWD/dist/quantum-bundle-v0.3.4-rc6.zip}"
WORK="$PWD/tests/.lifecycle-work"

cleanup() {
    docker rm -f "$CT" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    echo "== proof: no lifecycle test resources remain =="
    docker ps -a --format '{{.Names}}' | grep -x "$CT" && echo "LEFTOVER!" || echo "container: none ✓"
}
trap cleanup EXIT
docker info >/dev/null 2>&1 || { echo "SKIP: docker not reachable"; trap - EXIT; exit 0; }
[ -f "$ZIP" ] || { echo "FAIL: bundle zip missing"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
unzip -q "$ZIP" -d "$WORK"
BD="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -n "$BD" ] || { echo "FAIL: the zip has no top-level directory"; exit 1; }

docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" ubuntu:24.04 sleep 3600 >/dev/null
docker cp "$(cygpath -w "$BD")" "$CT":/bundle
docker exec "$CT" bash -c "chmod 755 /bundle/bin/* /bundle/install-*.sh"

echo "== A. agent --uninstall removes only Quantum-owned files =="
docker exec "$CT" bash -c '
set -e
# simulate a post-install state (the systemd-free container never gets that
# far with the real installer) + FOREIGN software that must survive
touch /usr/local/bin/pasarguard-node && chmod 755 /usr/local/bin/pasarguard-node
echo "foreign" > /etc/sysctl.d/99-other-software.conf
mkdir -p /etc/quantum-agent/desired && echo identity > /etc/quantum-agent/agent.json
mkdir -p /var/lib/quantum-agent && echo counters > /var/lib/quantum-agent/acct.json
printf "fake unit\n" > /etc/systemd/system/gre-agent.service
echo "hardening" > /etc/sysctl.d/99-quantum-hardening.conf
echo "forward" > /etc/sysctl.d/30-quantum-forward.conf
mkdir -p /etc/systemd/journald.conf.d && echo persistent > /etc/systemd/journald.conf.d/quantum-persistent.conf
cp /bundle/bin/quantum-agent-linux-amd64 /usr/local/bin/quantum-agent
cp /usr/local/bin/quantum-agent /usr/local/bin/quantum-agent.bak

/bundle/install-agent.sh --uninstall >/tmp/uninstall.log 2>&1 || { cat /tmp/uninstall.log; exit 1; }
echo "--- uninstall log:"; tail -12 /tmp/uninstall.log

for f in /etc/systemd/system/gre-agent.service \
         /etc/sysctl.d/99-quantum-hardening.conf \
         /etc/sysctl.d/30-quantum-forward.conf \
         /etc/systemd/journald.conf.d/quantum-persistent.conf \
         /usr/local/bin/quantum-agent /usr/local/bin/quantum-agent.bak; do
    [ ! -e "$f" ] || { echo "FAIL: $f still exists after --uninstall"; exit 1; }
done
[ -f /usr/local/bin/pasarguard-node ] || { echo "FAIL: foreign binary was removed!"; exit 1; }
[ -f /etc/sysctl.d/99-other-software.conf ] || { echo "FAIL: foreign sysctl file was removed!"; exit 1; }
[ -f /etc/quantum-agent/agent.json ] || { echo "FAIL: config/state removed without --purge!"; exit 1; }
[ -f /var/lib/quantum-agent/acct.json ] || { echo "FAIL: data removed without --purge!"; exit 1; }
echo "A-OK: quantum-owned files gone, config kept, foreign software untouched"
'

echo "== B. agent --purge removes the config/state dirs too =="
docker exec "$CT" bash -c '
set -e
# recreate the minimal state the purge should remove
mkdir -p /etc/quantum-agent/desired /var/lib/quantum-agent
/bundle/install-agent.sh --uninstall --purge >/tmp/purge.log 2>&1 || { cat /tmp/purge.log; exit 1; }
[ ! -d /etc/quantum-agent ] || { echo "FAIL: /etc/quantum-agent survived --purge"; exit 1; }
[ ! -d /var/lib/quantum-agent ] || { echo "FAIL: /var/lib/quantum-agent survived --purge"; exit 1; }
[ -f /usr/local/bin/pasarguard-node ] || { echo "FAIL: foreign binary removed by purge!"; exit 1; }
echo "B-OK: purge removed config+data, foreign software still untouched"
'

echo "== C. agent --upgrade: config kept, hash verified, ROLLS BACK when the service stays down =="
docker exec "$CT" bash -c '
set -e
# fake systemctl: restart always "works", is-active NEVER active — so the
# upgrade must roll back to the .bak and die non-zero
cat > /usr/local/bin/systemctl <<"EOF"
#!/bin/bash
case "$1" in
  restart|daemon-reload) echo "fake systemctl $1"; exit 0;;
  is-active) exit 3;;
  *) exit 0;;
esac
EOF
chmod 755 /usr/local/bin/systemctl
# existing install: OLD binary (the panel binary stands in), config marker
mkdir -p /etc/quantum-agent && echo "keep-me-config" > /etc/quantum-agent/agent.json
cp /bundle/bin/quantum-panel-linux-amd64 /usr/local/bin/quantum-agent
OLD_SUM=$(sha256sum /usr/local/bin/quantum-agent | cut -d" " -f1)
NEW_SUM=$(sha256sum /bundle/bin/quantum-agent-linux-amd64 | cut -d" " -f1)

set +e
/bundle/install-agent.sh --upgrade --binary /bundle/bin/quantum-agent-linux-amd64 --checksum "$NEW_SUM" >/tmp/upgrade.log 2>&1
RC=$?
set -e
echo "--- upgrade log:"; tail -8 /tmp/upgrade.log
[ "$RC" -ne 0 ] || { echo "FAIL: upgrade exited 0 although the fake service never went active"; exit 1; }
grep -q "rolling back" /tmp/upgrade.log || { echo "FAIL: no rollback happened"; exit 1; }
NOW_SUM=$(sha256sum /usr/local/bin/quantum-agent | cut -d" " -f1)
[ "$NOW_SUM" = "$OLD_SUM" ] || { echo "FAIL: binary was NOT rolled back"; exit 1; }
[ -f /etc/quantum-agent/agent.json ] && grep -q "keep-me-config" /etc/quantum-agent/agent.json \
    || { echo "FAIL: config was not kept"; exit 1; }
echo "C-OK: upgrade rolled back to the previous binary, config kept, exit non-zero"
'

echo "== D. panel --upgrade keeps config and rolls back identically =="
docker exec "$CT" bash -c '
set -e
rm -f /usr/local/bin/systemctl
cat > /usr/local/bin/systemctl <<"EOF"
#!/bin/bash
case "$1" in
  restart|daemon-reload) echo "fake systemctl $1"; exit 0;;
  is-active) exit 3;;
  *) exit 0;;
esac
EOF
chmod 755 /usr/local/bin/systemctl
mkdir -p /etc/quantum-panel && echo "panel-config-keep" > /etc/quantum-panel/panel.json
cp /bundle/bin/quantum-agent-linux-amd64 /usr/local/bin/quantum-panel   # stand-in "old" binary
OLD_SUM=$(sha256sum /usr/local/bin/quantum-panel | cut -d" " -f1)
NEW_SUM=$(sha256sum /bundle/bin/quantum-panel-linux-amd64 | cut -d" " -f1)

set +e
/bundle/install-panel.sh --upgrade --binary /bundle/bin/quantum-panel-linux-amd64 --checksum "$NEW_SUM" >/tmp/pupgrade.log 2>&1
RC=$?
set -e
echo "--- panel upgrade log:"; tail -8 /tmp/pupgrade.log
[ "$RC" -ne 0 ] || { echo "FAIL: panel upgrade exited 0 with a never-active service"; exit 1; }
grep -qi "roll" /tmp/pupgrade.log || { echo "FAIL: no rollback happened"; exit 1; }
NOW_SUM=$(sha256sum /usr/local/bin/quantum-panel | cut -d" " -f1)
[ "$NOW_SUM" = "$OLD_SUM" ] || { echo "FAIL: panel binary was NOT rolled back"; exit 1; }
grep -q "panel-config-keep" /etc/quantum-panel/panel.json || { echo "FAIL: panel config not kept"; exit 1; }
echo "D-OK: panel upgrade rolled back, config kept"
'

echo "== installer lifecycle test PASSED =="
