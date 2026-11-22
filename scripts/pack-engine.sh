#!/usr/bin/env bash
###############################################################################
# scripts/pack-engine.sh <engine> <version> [--from DIR] [--out DIR]
#
# Phase 6 TASK 4: build a panel-uploadable, SIGNED engine artifact from
# the upstream release — for amd64 AND arm64 (Iran = x86_64, Germany =
# ARM64). Per-engine knobs live in engines/<engine>.conf.
#
# Steps per arch:
#   1. fetch the upstream archive (or reuse --from/<name> pre-placed for
#      offline runs),
#   2. verify the upstream sha256 when the project publishes one,
#   3. repackage as the shape the agents extract: <inner>/<binaries> plus
#      the upstream LICENSE and a SOURCE.txt (upstream URL, tag, license,
#      upstream checksum or "not published"),
#   4. sha256 + ed25519-sign the artifact with the ENGINE-ARTIFACT key.
#
# The engine-artifact signing key stays OUTSIDE every repo (same custody
# rules as the release key): $ENGINE_SIGNING_KEY, default
# ~/.quantum-release/engine-signing.key. If it is missing a DEV key is
# generated and the fact is printed LOUDLY — replace it for production.
#
# Output: <out>/<engine>-<version>-pack/ with
#   <engine>-<version>-linux-<arch>.tar.gz / .tar.gz.sig (base64) / .tar.gz.sha256
#   UPLOAD-COMMANDS.txt (exact curl for POST /api/mesh/engines/artifacts)
###############################################################################
set -euo pipefail

ENGINE="${1:?usage: pack-engine.sh <engine> <version> [--from DIR] [--out DIR]}"
VERSION="${2:?usage: pack-engine.sh <engine> <version> [--from DIR] [--out DIR]}"
FROM=""; OUT=""
shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2;;
        --out)  OUT="$2"; shift 2;;
        *) echo "unknown flag: $1" >&2; exit 2;;
    esac
done
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || { echo "bad version"; exit 2; }
VER="${VERSION#v}"   # upstream templates use the bare version
CONF="${ENGINE_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../engines" && pwd)/$ENGINE.conf}"
[ -f "$CONF" ] || { echo "no engine config: $CONF"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-$RELEASE_ROOT/dist}"
OUTDIR="$OUT/$ENGINE-$VERSION-pack"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"
# Conf files may carry CRLF (checked out on Windows) — sanitize first.
CONF_CLEAN="$WORK/engine.conf"
tr -d '\r' < "$CONF" > "$CONF_CLEAN"
# shellcheck disable=SC1090
source "$CONF_CLEAN"

fetch() { # url dest
    if [ -n "$FROM" ] && [ -f "$FROM/$(basename "$2")" ]; then
        cp "$FROM/$(basename "$2")" "$2"; echo "offline: $(basename "$2")"
        return 0
    fi
    curl -fsSL --retry 3 -o "$2" "$1"
}

tpl() { sed -e "s/<ver>/$VER/g" <<< "$1"; }

SIGNING_KEY="${ENGINE_SIGNING_KEY:-$HOME/.quantum-release/engine-signing.key}"
if [ ! -f "$SIGNING_KEY" ]; then
    mkdir -p "$(dirname "$SIGNING_KEY")"
    openssl genpkey -algorithm ed25519 -out "$SIGNING_KEY" 2>/dev/null
    chmod 600 "$SIGNING_KEY"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! GENERATED A DEV ENGINE-SIGNING KEY at $SIGNING_KEY"
    echo "!! Use a properly-custodied production key before shipping;"
    echo "!! the agent build must pin the matching public key."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    DEV_KEY=1
fi
PUB_B64="$(openssl pkey -in "$SIGNING_KEY" -pubout -outform DER 2>/dev/null | base64 -w0)"
# RUNBOOK-FIXES 27: print the key FINGERPRINT — build-release.sh prints the
# same fingerprint for the agent pin; they must match.
echo "engine-key pin fingerprint: $(printf '%s' "$PUB_B64" | sha256sum | awk '{print substr($1,1,16)}') (pack-engine.sh)"

UPSTREAM_SHA_NOTE="upstream checksum: not published by the project"
# Public key snippet for the agent build (must match the panel's
# engine-pub.b64) — written BEFORE the per-arch loop so even a PARTIAL
# pack (one arch failed upstream) self-identifies the key its artifacts
# were signed with; verify-engines.sh depends on it.
{
    echo "engine-artifact public key (base64 DER SPKI) for the panel's"
    echo "engine-artifacts/engine-pub.b64 AND the agent build pin:"
    echo "$PUB_B64"
    if [ -n "${DEV_KEY:-}" ]; then
        echo "WARNING: this is a freshly generated DEV key — replace before production."
    fi
} > "$OUTDIR/ENGINE-PUB-KEY.txt"

for ARCH in amd64 arm64; do
    URLVAR="URL_$(echo "$ARCH" | tr a-z A-Z)"
    URL="$(tpl "${!URLVAR:?missing $URLVAR in $CONF}")"
    ARC="$WORK/$ENGINE-$VER-$ARCH.tgz"
    UPNAME="$(basename "$URL")"
    echo "== $ARCH: $URL"
    if [ -n "$FROM" ] && [ -f "$FROM/$UPNAME" ]; then
        cp "$FROM/$UPNAME" "$ARC"; echo "   offline: $UPNAME"
    else
        fetch "$URL" "$ARC" || { echo "  DOWNLOAD FAILED: $URL" >&2; exit 1; }
        [ -s "$ARC" ] || { echo "  DOWNLOAD EMPTY: $URL" >&2; exit 1; }
    fi
    # Upstream checksum verification WHEN published.
    if [ -n "${SHA_URL:-}" ]; then
        SUMS="$WORK/upstream-sums-$ARCH.txt"
        if fetch "$(tpl "$SHA_URL")" "$SUMS" 2>/dev/null; then
            # The sums file lists UPSTREAM asset names; ARC's local name is
            # <engine>-<ver>-<arch>.tgz regardless of the upstream shape —
            # try the upstream name (fixed-string) first, then the local one.
            want="$( { grep -F "$UPNAME" "$SUMS" || grep -F "$(basename "$ARC")" "$SUMS"; } | awk '{print $1}' | head -1)"
            got="$(sha256sum "$ARC" | awk '{print $1}')"
            if [ -z "$want" ]; then
                echo "   NOTE: upstream checksum file has no entry for $(basename "$ARC") — skipped"
            elif [ "$want" != "$got" ]; then
                echo "UPSTREAM CHECKSUM MISMATCH for $ARC: want $want got $got" >&2
                exit 1
            else
                echo "   upstream checksum OK ($got)"
                UPSTREAM_SHA_NOTE="upstream checksum: $got (verified)"
            fi
        else
            echo "   NOTE: upstream checksum file unreachable — skipped"
        fi
    else
        echo "   $UPSTREAM_SHA_NOTE"
    fi

    # PASSTHROUGH packs (RC10-PREP): with PASSTHROUGH=1 in the conf, the
    # fetched archive IS the artifact — byte-identical to the published
    # quantum-cores release asset (the cores side packaged + digest-verified
    # it: OVERNIGHT-C hysteria/sing-box, C2+A4 waterwall, D2 easytier, the
    # A5 xray v26.3.27 repackage). The pack re-signs those bytes with the
    # ENGINE-ARTIFACT key, so verify-engines.sh's ledger rail (pack sha256
    # == ledger manifest sha256) holds BY CONSTRUCTION. The ledger digest
    # (<ENGINE>-v<VER> assets[linux-<arch>] in QUANTUM_CORES_DIR or the
    # sibling ../quantum-cores) is the canonical verify — a drift or a
    # missing ledger asset is FATAL unless the documented ledger downgrade
    # is set (then SHA_URL, when configured, is the only check).
    if [ "${PASSTHROUGH:-0}" = "1" ]; then
        NAME="$ENGINE-$VERSION-linux-$ARCH.tar.gz"
        cp "$ARC" "$OUTDIR/$NAME"
        LEDGER_DIR="${QUANTUM_CORES_DIR:-$RELEASE_ROOT/../quantum-cores}"
        LSHA="$(python3 - "$LEDGER_DIR" "$ENGINE" "$ENGINE-v$VERSION" "linux-$ARCH" <<'PYPASS'
import json, os, sys
ledger, core, tag, osarch = sys.argv[1:5]
p = os.path.join(ledger, core, "MANIFEST.json")
try:
    d = json.load(open(p, encoding="utf-8"))
except FileNotFoundError:
    print("")
    raise SystemExit(0)
for v in d.get("versions", []):
    if v.get("tag") == tag:
        a = (v.get("assets") or {}).get(osarch) or {}
        print(a.get("sha256", ""))
        break
PYPASS
)" || LSHA=""
        if [ -z "$LSHA" ] && [ "${QUANTUM_ALLOW_NO_CORES_LEDGER:-0}" != "1" ] && [ ! -d "$LEDGER_DIR" ]; then
            echo "FATAL: passthrough pack needs the quantum-cores ledger at $LEDGER_DIR (no $ENGINE-v$VERSION manifest found) — set QUANTUM_CORES_DIR or QUANTUM_ALLOW_NO_CORES_LEDGER=1 (documented downgrade)" >&2
            exit 1
        fi
        if [ -n "$LSHA" ]; then
            GOT="$(sha256sum "$OUTDIR/$NAME" | awk '{print $1}')"
            if [ "$GOT" != "$LSHA" ]; then
                echo "LEDGER FAIL: $NAME sha256 drift — pack ${GOT:0:16}… vs ledger ${LSHA:0:16}…" >&2
                exit 1
            fi
            echo "   ledger sha256 OK (byte-identical to the $ENGINE-v$VERSION cores asset)"
        else
            echo "   WARNING: LEDGER SKIPPED (QUANTUM_ALLOW_NO_CORES_LEDGER=1) — passthrough sha256 not verified against the ledger" >&2
        fi
        if [ ! -f "$OUTDIR/LICENSE-$ENGINE.txt" ] && [ -n "${LICENSE_URL:-}" ]; then
            fetch "$(tpl "$LICENSE_URL")" "$OUTDIR/LICENSE-$ENGINE.txt" 2>/dev/null || true
        fi
        echo "   passthrough: $NAME (no repack — the cores asset is the artifact)"
    else
    # Extract and repackage: <inner>/ with binaries + LICENSE + SOURCE.txt.
    # Upstream shapes handled: tar.gz (most), FLAT .gz single binaries
    # (chisel), ZIP (rathole, Xray-core) and single-bundle tar.gz with
    # per-arch binary names (udp2raw — use {arch} in BINARIES).
    SRC="$WORK/src-$ARCH"
    rm -rf "$SRC"; mkdir -p "$SRC"
    # INNER names the directory the REPACKED tarball carries; when the
    # conf omits it, default to <engine>_<ver> (never empty — tar -czf ""
    # creates an "empty member name" archive).
    INNER_DIR="$(tpl "${INNER:-${ENGINE}_${VER}}")"
    ARCHNAME="$ARCH"                     # {arch} in BINARIES/UPSTREAM_BIN
    case "$ARCH" in
        arm64) ARCHNAME="${UPSTREAM_ARM64_NAME:-arm64}";;
    esac
    case "$UPNAME" in
        *.tar.gz|*.tgz)
            tar -xzf "$ARC" -C "$SRC"
            BASE="$SRC/${INNER_DIR:-}"
            [ -d "$BASE" ] || BASE="$SRC"
            ;;
        *.gz)
            FIRSTBIN="${BINARIES%% *}"
            gunzip -c "$ARC" > "$SRC/$FIRSTBIN"
            chmod 755 "$SRC/$FIRSTBIN"
            BASE="$SRC"
            ;;
        *.zip)
            ( cd "$SRC" && unzip -q "$ARC" ) || { echo "  unzip failed: $ARC" >&2; exit 1; }
            BASE="$SRC/${INNER_DIR:-}"
            [ -d "$BASE" ] || BASE="$SRC"
            ;;
        *)
            # RAW single-file assets (e.g. CIAUB/C-Tunnel ships bare ELF
            # binaries with no archive wrapper): accept only when the
            # fetched file really is an ELF binary (magic 7f 45 4c 46) —
            # anything else keeps the unknown-shape error.
            if [ "$(head -c4 "$ARC" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
                FIRSTBIN="${BINARIES%% *}"
                cp "$ARC" "$SRC/$FIRSTBIN"
                chmod 755 "$SRC/$FIRSTBIN"
                BASE="$SRC"
            else
                echo "unknown archive shape: $ARC" >&2; exit 1
            fi;;
    esac
    ART="$WORK/pack-$ARCH"
    mkdir -p "$ART/$INNER_DIR"
    for BIN in $BINARIES; do
        # {arch} in a binary name = the upstream ships per-arch names
        # inside ONE bundle (udp2raw_amd64 / udp2raw_aarch64).
        WANT="$(sed "s/{arch}/$ARCHNAME/g" <<< "$BIN")"
        FOUND="$(find "$SRC" -type f -name "$WANT" | head -1)"
        if [ -z "$FOUND" ]; then
            echo "binary $WANT not found in upstream archive" >&2
            exit 1
        fi
        cp "$FOUND" "$ART/$INNER_DIR/$BIN"
        chmod 755 "$ART/$INNER_DIR/$BIN"
    done
    # LICENSE: fetch once per engine (arch-independent); fall back to any
    # LICENSE file inside the upstream archive.
    LIC="$OUTDIR/LICENSE-$ENGINE.txt"
    if [ ! -f "$LIC" ] && [ -n "${LICENSE_URL:-}" ]; then
        fetch "$(tpl "$LICENSE_URL")" "$LIC" 2>/dev/null || true
    fi
    if [ ! -f "$LIC" ]; then
        find "$SRC" -maxdepth 2 -iname "LICENSE*" -exec cp {} "$LIC" \; 2>/dev/null || true
    fi
    [ -f "$LIC" ] && cp "$LIC" "$ART/$INNER_DIR/LICENSE"
    {
        echo "engine: $ENGINE"
        echo "version: $VERSION"
        echo "upstream: ${UPSTREAM:-unknown}"
        echo "upstream tag: v$VER"
        echo "license: ${LICENSE_NAME:-unknown} (text shipped in this archive)"
        echo "$UPSTREAM_SHA_NOTE"
        echo "packed: $(date -u '+%Y-%m-%dT%H:%MZ') by quantum-release scripts/pack-engine.sh"
        echo "note: repackaged for the Quantum agent extract path (expects <$INNER_DIR>/<binary>)"
    } > "$ART/$INNER_DIR/SOURCE.txt"

    NAME="$ENGINE-$VERSION-linux-$ARCH.tar.gz"
    ( cd "$ART" && tar -czf "$OUTDIR/$NAME" "$INNER_DIR" )
    fi   # PASSTHROUGH branch (repack path only)
    SHA="$(sha256sum "$OUTDIR/$NAME" | awk '{print $1}')"
    echo "$SHA  $NAME" > "$OUTDIR/$NAME.sha256"
    openssl pkeyutl -sign -rawin -inkey "$SIGNING_KEY" -in "$OUTDIR/$NAME" -out "$WORK/$NAME.sig"
    base64 -w0 "$WORK/$NAME.sig" > "$OUTDIR/$NAME.sig.b64"
    {
        echo "== $NAME"
        echo "sha256: $SHA"
        echo "signature (base64 ed25519): see $NAME.sig.b64"
        echo
        echo "# exact upload for the panel Engines tab API (operator session):"
        echo "#   1) log into the panel UI and copy the gre_csrf cookie value"
        echo "curl -k -X POST 'https://<panel-host>/<base>/api/mesh/engines/artifacts' \\"
        echo "  -H 'X-CSRF-Token: <gre_csrf cookie>' -b 'gre_session=<session cookie>' \\"
        echo "  -F 'engine=$ENGINE' -F 'version=$VERSION' -F 'goarch=$ARCH' -F 'goos=linux' \\"
        echo "  -F 'name=$NAME' \\"
        echo "  -F \"signature=\$(cat $NAME.sig.b64)\" \\"
        echo "  -F 'file=@$NAME'"
        echo
    } >> "$OUTDIR/UPLOAD-COMMANDS.txt"
    echo "   packed: $NAME (sha256 $SHA)"
done

echo "DONE: $OUTDIR"
ls -la "$OUTDIR"
