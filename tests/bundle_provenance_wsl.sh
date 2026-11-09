#!/usr/bin/env bash
# bundle_provenance_wsl.sh <bundle-zip> — run under WSL: extract the zip,
# run the bundle's panel binary, compare its version --json sha against the
# bundle's signed MANIFEST.json. Exits non-zero on any mismatch.
set -euo pipefail
Z="${1:?usage: bundle_provenance_wsl.sh <bundle.zip>}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
unzip -q "$Z" -d "$W"
BD="$(find "$W" -maxdepth 1 -mindepth 1 -type d | head -1)"
BIN="$BD/bin/quantum-panel-linux-amd64"
chmod 755 "$BIN"
MAN="$("$BIN" version --json > "$W/vj.json"; python3 - "$BD/MANIFEST.json" "$W/vj.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
r = json.load(open(sys.argv[2]))
print(m["sources"]["panel"]["sha"])
if r["sha"] != m["sources"]["panel"]["sha"]:
    sys.stderr.write("PROVENANCE MISMATCH: binary %s != MANIFEST %s\n" % (r["sha"], m["sources"]["panel"]["sha"]))
    sys.exit(1)
PY
)"
echo "MANIFEST panel sha == binary self-report: $MAN"
echo PROVENANCE-OK
