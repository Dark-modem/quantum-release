#!/usr/bin/env bash
# tests/bundle_smoke.sh — bundle smoke: start the panel BINARY FROM THE
# RELEASE ZIP in a container, fetch the dashboard HTML/JS and assert the UI
# markers are really inside (the phase-8 lesson: announced features must be
# IN the shipped binary), and assert the binary's version --json provenance
# matches the bundle's MANIFEST.json. Container is removed afterwards with
# proof.
#
# BACKEND-27: parameterized — the rc6 zip/version/container names were
# hardcoded, which made the test unusable for any other bundle.
# Usage: bundle_smoke.sh [bundle-zip] [expected-version]   (defaults: rc6)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # container paths must not become C:\Program Files\Git\...
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ZIP="${1:-$PWD/dist/quantum-bundle-v0.3.4-rc6.zip}"
EXPECT_VER="${2:-v0.3.4-rc6}"
CT="${BUNDLE_SMOKE_CT:-quantum-test-bundle}"
ZIP_ABS="$(cygpath -w "$ZIP")"
# Git Bash /c/... → WSL /mnt/c/...
to_wsl() { printf '%s' "$1" | sed -E 's|^/([a-zA-Z])/|/mnt/\1/|'; }
ZIP_WSL="$(to_wsl "$(cygpath -u "$ZIP")")"
PROV_WSL="$(to_wsl "$(cygpath -u "$PWD/tests/bundle_provenance_wsl.sh")")"
cleanup() {
    docker rm -f "$CT" >/dev/null 2>&1 || true
    echo "== proof: the smoke container is gone =="
    docker ps -a --format '{{.Names}}' | grep -x "$CT" && echo "LEFTOVER!" || echo "$CT: none ✓"
}
trap cleanup EXIT
docker info >/dev/null 2>&1 || { echo "SKIP: docker not reachable"; trap - EXIT; exit 0; }
[ -f "$ZIP" ] || { echo "FAIL: zip missing: $ZIP"; exit 1; }

echo "== provenance: the bundle panel binary self-report must match MANIFEST.json =="
# both the run and the comparison happen under WSL (linux ELF + python3)
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -- bash "$PROV_WSL" "$ZIP_WSL"
echo "== starting the bundle panel in container $CT =="
PORT=18099
docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" -p "127.0.0.1:${PORT}:8000" \
    mcr.microsoft.com/playwright/python:v1.49.0-jammy sleep 3600 >/dev/null
docker cp "$ZIP_ABS" "$CT":/bundle.zip
docker exec -i "$CT" python - <<'PYSETUP'
import zipfile, os, stat
z = zipfile.ZipFile('/bundle.zip')
z.extractall('/smoke')
bd = '/smoke/' + [n for n in z.namelist() if n.endswith('/bin/quantum-panel-linux-amd64')][0].split('/bin/')[0]
os.chmod(bd + '/bin/quantum-panel-linux-amd64', 0o755)
os.makedirs('/cfg', exist_ok=True)
open('/cfg/panel.json', 'w').write('{"base_path":"ui","port":8000}')
print('extracted to', bd)
PYSETUP
docker exec "$CT" bash -c "export GRE_PANEL_DIR=/cfg; /smoke/*/bin/quantum-panel-linux-amd64 password bundle-smoke-secret" >/dev/null 2>&1 || true
docker exec -d "$CT" bash -c "export GRE_PANEL_DIR=/cfg; /smoke/*/bin/quantum-panel-linux-amd64 > /panel.log 2>&1"
up=0
for i in $(seq 1 15); do
    code="$(docker exec "$CT" python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/ui/api/health', timeout=2).status)" 2>/dev/null | tail -1 || true)"
    [ "$code" = "200" ] && { up=1; break; }
    sleep 2
done
[ "$up" = "1" ] || { echo "FAIL: bundle panel never answered"; docker exec "$CT" tail -20 /panel.log || true; exit 1; }
echo "bundle panel is up"

echo "== fetching the dashboard + its assets and asserting the phase-11/A3 UI markers =="
docker exec -i "$CT" python - "$EXPECT_VER" <<'PYMARK'
import urllib.request, sys, re
base = 'http://127.0.0.1:8000'
VER = sys.argv[1]
def get(p):
    return urllib.request.urlopen(base + p, timeout=5).read().decode()
html = get('/ui/')
fails = []

def want(name, cond):
    print(('  marker OK: ' if cond else '  marker MISSING: ') + name)
    if not cond:
        fails.append(name)

# the dashboard itself carries the version stamp of THIS release
want('version stamp ' + VER + ' in dashboard', VER in html)
# the phase-11 mesh management UI is served standalone (mesh.js)
mesh = get('/ui/mesh.js')
want('mesh.js served with the mesh wizard', len(mesh) > 50000 and 'mesh-wizard' in mesh)
# the mesh stylesheet is served and styles the per-tunnel weights
css = get('/ui/quantum-mesh.css')
want('quantum-mesh.css served with weight styles', len(css) > 15000 and 'weight' in css)
# app.js: topology wizard + per-tunnel weights interactions
app = get('/ui/app.js')
want('app.js wizard flow', 'wizard' in app)
want('app.js per-tunnel weights', 'weight' in app)
# engines tab (engine management with enable/disable)
want('app.js engine management', 'engine' in app)
if fails:
    sys.exit(1)
print('ALL PHASE-11/A3 MARKERS PRESENT IN THE BUNDLE PANEL')
PYMARK
echo "MARKERS-OK"
echo "== bundle smoke PASSED =="
