#!/usr/bin/env bash
# verify-bundle.sh <zip> — verify a Quantum release bundle BEFORE installing
# it (RUNBOOK-FIXES 25/31; phase 14). An operator or session 3 runs this on
# any machine with unzip + openssl; root is not needed.
#
# Checks, in order:
#   1. the zip contains MANIFEST.json + MANIFEST.json.sig + bin/checksums.txt
#      + bin/checksums.txt.sig + signing-public.pem + the two installers
#   2. MANIFEST.json's signature verifies against signing-public.pem
#   3. every file listed in bin/checksums.txt matches its sha256, and
#      checksums.txt's own signature verifies
#   4. MANIFEST.json's internal consistency: the binary sha256s recorded in
#      the MANIFEST match the checksums.txt entries; panel/agent version --
#      json self-reports match the MANIFEST's announced SHAs and versions
#   5. the RC line that RELEASE-READY.md must carry (print it for diffing)
#
# Usage: verify-bundle.sh quantum-bundle-vX.zip
set -uo pipefail

ZIP="${1:?usage: verify-bundle.sh <quantum-bundle.zip>}"
command -v unzip >/dev/null || { echo "need unzip"; exit 2; }
command -v openssl >/dev/null || { echo "need openssl"; exit 2; }
command -v python3 >/dev/null || { echo "need python3"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }
ok() { echo "VERIFY OK: $*"; }

unzip -q "$ZIP" -d "$WORK" || fail "cannot unzip $ZIP"
D="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -n "$D" ] || fail "the zip has no top-level directory"
echo "== bundle: $(basename "$ZIP") =="

# 1. presence
for f in MANIFEST.json MANIFEST.json.sig bin/checksums.txt bin/checksums.txt.sig \
         signing-public.pem install-agent.sh install-panel.sh; do
    [ -f "$D/$f" ] || fail "missing $f"
done
ok "all required files present"

# 2. MANIFEST signature (against the bundle's own public key)
openssl pkeyutl -verify -rawin -pubin -inkey "$D/signing-public.pem" \
    -in "$D/MANIFEST.json" -sigfile "$D/MANIFEST.json.sig" >/dev/null 2>&1 \
    || fail "MANIFEST.json signature does NOT verify against signing-public.pem"
ok "MANIFEST.json signature verified"

# 3. checksums.txt contents + signature
( cd "$D/bin" && sha256sum -c checksums.txt >/dev/null 2>&1 ) \
    || fail "bin/checksums.txt does not match the shipped files"
ok "every shipped file matches bin/checksums.txt"
openssl pkeyutl -verify -rawin -pubin -inkey "$D/signing-public.pem" \
    -in "$D/bin/checksums.txt" -sigfile "$D/bin/checksums.txt.sig" >/dev/null 2>&1 \
    || fail "checksums.txt signature does NOT verify"
ok "checksums.txt signature verified"

# 4. MANIFEST internal consistency
python3 - "$D" <<'PY' || exit 1
import json, os, sys, hashlib

d = sys.argv[1]
man = json.load(open(os.path.join(d, "MANIFEST.json")))
sums = {}
for line in open(os.path.join(d, "bin", "checksums.txt")):
    h, _, name = line.strip().partition("  ")
    sums[name.strip()] = h

for bname, info in man["binaries"].items():
    if bname not in sums:
        sys.exit("FATAL: MANIFEST binary %s is missing from checksums.txt" % bname)
    if info["sha256"] != sums[bname]:
        sys.exit("FATAL: MANIFEST sha256 for %s != checksums.txt" % bname)
    real = hashlib.sha256(open(os.path.join(d, "bin", bname), "rb").read()).hexdigest()
    if real != info["sha256"]:
        sys.exit("FATAL: %s content sha256 != MANIFEST" % bname)

# run the amd64 binaries if this host can (self-reported vs announced)
amd_panel = os.path.join(d, "bin", "quantum-panel-linux-amd64")
amd_agent = os.path.join(d, "bin", "quantum-agent-linux-amd64")
if os.uname().machine == "x86_64" and os.access(amd_panel, os.X_OK):
    pj = json.loads(os.popen(amd_panel + " version --json").read())
    if pj.get("sha") != man["sources"]["panel"]["sha"]:
        sys.exit("FATAL: panel self-reported sha != MANIFEST sources.panel.sha")
    if pj.get("version") != man["release"]:
        sys.exit("FATAL: panel self-reported version != MANIFEST release")
    if pj.get("migrations") != man.get("panel_migrations"):
        sys.exit("FATAL: panel migrations != MANIFEST")
    print("   panel self-report matches the MANIFEST (amd64 ran)")
    aj = json.loads(os.popen(amd_agent + " version --json").read())
    if aj.get("sha") != man["sources"]["agent"]["sha"]:
        sys.exit("FATAL: agent self-reported sha != MANIFEST sources.agent.sha")
    if sorted(aj.get("engines", [])) != sorted(man.get("agent_engines", [])):
        sys.exit("FATAL: agent engines != MANIFEST agent_engines")
    if sorted(aj.get("engines", [])) != sorted(man.get("expected_agent_engines", [])):
        sys.exit("FATAL: agent engines != MANIFEST expected_agent_engines (source)")
    print("   agent self-report matches the MANIFEST incl. the engine set (amd64 ran)")
else:
    print("   (not x86_64 or binaries not executable: skipping the live self-report check)")

print("   MANIFEST internal consistency OK")
PY

# 5. the RELEASE-READY RC line, generated from the MANIFEST
python3 - "$D" <<'PY' || exit 1
import json, os, sys
d = sys.argv[1]
m = json.load(open(os.path.join(d, "MANIFEST.json")))
print("RC6: dist/quantum-bundle-{}.zip <zip-sha256> protocol {} panel {} agent {} engines {}".format(
    m["release"], m["sources"]["protocol"]["sha"], m["sources"]["panel"]["sha"],
    m["sources"]["agent"]["sha"], m.get("engines_folder", "dist/engines-2026-11-08/")))
PY
ok "bundle verified end to end"
