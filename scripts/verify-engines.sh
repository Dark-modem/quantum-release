#!/usr/bin/env bash
# verify-engines.sh [engines-dir] [engine-pub-b64-file]
# Verifies a packed engines folder (pack-all-engines.sh output) against the
# engine-artifact key the shipped agent binaries pin: every pack's
# ENGINE-PUB-KEY.txt must equal the pinned key, and every artifact must
# match its sha256 file AND its ed25519 signature. Exit 0 only if all pass.
# (phase 14: the 2026-11-08 packs were signed with a key that no longer
# exists — this check makes that impossible to miss again.)
DIR="${1:-dist/engines-2026-11-09}"
PINFILE="${2:-dist/quantum-bundle-v0.3.4-rc6/bin/engine-pub.b64}"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
PINB64=$(tr -d '[:space:]' < "$PINFILE")
PIN=$(printf '%s' "$PINB64" | sha256sum | awk '{print substr($1,1,16)}')
echo "bundle pin fingerprint: $PIN"

cd "$DIR" || { echo "no dir $DIR"; exit 1; }
FAIL=0; OK=0
for PK in *-pack; do
    [ -d "$PK" ] || continue
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
    for ART in "$PK"/*.tar.gz; do
        [ -e "$ART" ] || continue
        SHAFILE="$ART.sha256"; SIGB64="$ART.sig.b64"
        if ( cd "$PK" && sha256sum -c "$(basename "$SHAFILE")" >/dev/null 2>&1 ); then
            OK=$((OK+1))
        else
            echo "SHA FAIL: $SHAFILE"; FAIL=1; continue
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
rm -f /tmp/eng-pub.pem
exit $FAIL
