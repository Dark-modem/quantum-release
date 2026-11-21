#!/usr/bin/env bash
# verify-engines.sh [engines-dir] [engine-pub-b64-file]
# Verifies a packed engines folder (pack-all-engines.sh output) against
# the engine-artifact key the shipped agent binaries pin: every pack's
# ENGINE-PUB-KEY.txt must equal the pinned key, and every artifact must
# match its sha256 file AND its ed25519 signature. Exit 0 only if all pass.
# (phase 14: the 2026-11-08 packs were signed with a key that no longer
# exists — this check makes that impossible to miss again.)
#
# CORES-2 LEDGER MOVE: the pack set is additionally cross-checked against
# the Dark-modem/quantum-cores MANIFEST.json files — the CANONICAL expected
# mapping of cores/versions/assets (the published GitHub releases carry the
# same data as release assets). For every pack dir <core>-<version>-pack:
#   - the ledger must hold <core>/MANIFEST.json with that version (tag
#     <core>-v<version>) — a pack with no ledger manifest is FATAL (a new
#     engine without a published core stops the pipeline here);
#   - every artifact in the pack must appear in that ledger version's
#     assets with the SAME sha256, and every ledger asset of that version
#     must be present in the pack — drift either way is FATAL.
# Exempt engines (no pack, no manifest): matrix (in-process engine shipping
# with the agent binary) and wireguard (host kernel module) — documented in
# the ledger README "Exemptions". Neither ever appears as a pack.
#
# LEDGER SOURCE (least fragile, by CORES-2 decision): a LOCAL clone only,
# no network at run time — $QUANTUM_CORES_DIR, else the sibling
# ../quantum-cores of this repo (the 01-REPOSITORIES workspace layout).
# A missing ledger is FATAL unless QUANTUM_ALLOW_NO_CORES_LEDGER=1 — the
# documented downgrade to the legacy behavior (key pin + sha256 + sig
# self-consistency only, ledger cross-check SKIPPED loudly; runner scripts
# for builds from WSL-side clones must set QUANTUM_CORES_DIR accordingly).
DIR="${1:-dist/engines-2026-11-09}"
PINFILE="${2:-dist/quantum-bundle-v0.3.5-rc8/bin/engine-pub.b64}"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT="$PWD"
LEDGER="${QUANTUM_CORES_DIR:-$REPO_ROOT/../quantum-cores}"
PINB64=$(tr -d '[:space:]' < "$PINFILE")
PIN=$(printf '%s' "$PINB64" | sha256sum | awk '{print substr($1,1,16)}')
echo "bundle pin fingerprint: $PIN"

LEDGER_MANIFESTS=""
PACKOK=0
if [ -d "$LEDGER" ]; then
    LEDGER_MANIFESTS=$(python3 - "$LEDGER" <<'PYEOF'
import glob, json, os, sys
rows = []
for mf in sorted(glob.glob(os.path.join(sys.argv[1], "*", "MANIFEST.json"))):
    d = json.load(open(mf, encoding="utf-8"))
    for v in d.get("versions", []):
        for osarch, a in sorted(v.get("assets", {}).items()):
            rows.append("%s|%s|%s|%s" % (d["core"], v["tag"], osarch.split("-")[-1], a["sha256"]))
print("\n".join(rows))
PYEOF
    ) || { echo "LEDGER ERROR: could not parse the quantum-cores manifests at $LEDGER"; exit 1; }
    echo "ledger: $LEDGER (quantum-cores clone)"
elif [ "${QUANTUM_ALLOW_NO_CORES_LEDGER:-0}" = "1" ]; then
    echo "WARNING: LEDGER SKIPPED — no quantum-cores clone at $LEDGER (QUANTUM_ALLOW_NO_CORES_LEDGER=1): legacy self-consistency checks only, the ledger cross-check is OFF"
else
    echo "FATAL: quantum-cores ledger not found at $LEDGER — set QUANTUM_CORES_DIR to a clone of https://github.com/Dark-modem/quantum-cores (public) or keep it as the sibling ../quantum-cores of this repo, or set QUANTUM_ALLOW_NO_CORES_LEDGER=1 (documented downgrade: ledger cross-check skipped)"
    exit 1
fi

cd "$DIR" || { echo "no dir $DIR"; exit 1; }
FAIL=0; OK=0
for PK in *-pack; do
    [ -d "$PK" ] || continue
    # ledger identity: <core>-<version>-pack
    BASE="${PK%-pack}"
    CORE="${BASE%-*}"; VER="${BASE#*-}"; TAG="$CORE-v$VER"
    if [ -n "$LEDGER_MANIFESTS" ]; then
        if ! printf '%s\n' "$LEDGER_MANIFESTS" | grep -qF "$CORE|$TAG|"; then
            echo "LEDGER FAIL: $PK has no manifest for tag $TAG in quantum-cores — pack + publish the core or drop the pack"
            FAIL=1
        else
            PACKOK=$((PACKOK+1))
        fi
    fi
    KEYTXT="$PK/ENGINE-PUB-KEY.txt"
    if [ ! -f "$KEYTXT" ]; then
        echo "NO ENGINE-PUB-KEY.txt in $PK"
        FAIL=1; continue
    fi
    # the b64 DER SPKI is the last base64-looking line of the file
    PKB64=$(grep -E '^[A-Za-z0-9+/]+={0,2}$' "$KEYTXT" | tail -1 | tr -d '[:space:]')
    PKFP=$(printf '%s' "$PKB64" | sha256sum | awk '{print substr($1,1,16)}')
    if [ "$PKFP" != "$PIN" ]; then
        echo "KEY MISMATCH in $PK (pack $PKFP != pin $PIN)"; FAIL=1; continue
    fi
    openssl pkey -pubin -in <(printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' \
        "$(printf '%s' "$PKB64" | fold -w 64)") -out /tmp/eng-pub.pem 2>/dev/null || { echo "bad key file in $PK"; FAIL=1; continue; }
    if [ -n "$LEDGER_MANIFESTS" ]; then
        LWANT=$(printf '%s\n' "$LEDGER_MANIFESTS" | grep -cF "$CORE|$TAG|")
        LGOT=$(ls "$PK"/*.tar.gz 2>/dev/null | wc -l)
        if [ "$LWANT" -ne "$LGOT" ]; then
            echo "LEDGER FAIL: $PK holds $LGOT artifacts but the ledger lists $LWANT for $TAG"
            FAIL=1
        fi
    fi
    for ART in "$PK"/*.tar.gz; do
        [ -e "$ART" ] || continue
        SHAFILE="$ART.sha256"; SIGB64="$ART.sig.b64"
        if ( cd "$PK" && sha256sum -c "$(basename "$SHAFILE")" >/dev/null 2>&1 ); then
            OK=$((OK+1))
        else
            echo "SHA FAIL: $SHAFILE"; FAIL=1; continue
        fi
        if [ -n "$LEDGER_MANIFESTS" ]; then
            GOARCH="${ART##*-}"; GOARCH="${GOARCH%.tar.gz}"
            LSHA=$(printf '%s\n' "$LEDGER_MANIFESTS" | grep -F "$CORE|$TAG|$GOARCH|" | head -1 | cut -d'|' -f4)
            if [ -z "$LSHA" ]; then
                echo "LEDGER FAIL: $(basename "$ART") is not in the quantum-cores ledger (no $TAG asset for $GOARCH)"
                FAIL=1
            else
                ASHA=$(cut -d' ' -f1 "$SHAFILE")
                if [ "$ASHA" != "$LSHA" ]; then
                    echo "LEDGER FAIL: $(basename "$ART") sha256 drift — store ${ASHA:0:16}… vs ledger ${LSHA:0:16}…"
                    FAIL=1
                fi
            fi
        fi
        if base64 -d "$SIGB64" | openssl pkeyutl -verify -rawin -pubin -inkey /tmp/eng-pub.pem \
            -in "$ART" -sigfile /dev/stdin >/dev/null 2>&1; then
            OK=$((OK+1))
        else
            echo "SIG FAIL: $SIGB64"; FAIL=1
        fi
    done
done
echo "verified: $OK artifact checks passed (sha256 + ed25519 sig each)"
if [ -n "$LEDGER_MANIFESTS" ]; then
    echo "ledger: $PACKOK packs matched their quantum-cores MANIFEST.json (no unmapped/unledgered packs)"
fi
rm -f /tmp/eng-pub.pem
exit $FAIL
