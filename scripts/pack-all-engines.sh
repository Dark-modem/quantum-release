#!/usr/bin/env bash
###############################################################################
# scripts/pack-all-engines.sh <outdir> [engine=version ...]
#
# Packs EVERY engine that needs an upstream binary, at the versions the
# drivers pin (read from internal/agent driver code — kept in sync here):
#
#   frp 0.61.1 · backhaul 0.7.2 · rathole 0.5.0 · gost 3.3.3 ·
#   wstunnel 10.1.9 · chisel 1.10.1 · xray 26.3.27 · udp2raw 20230206.0 ·
#   ctunnel 2.0.0 (packed FROM the human-provided source snapshot via --from
#   staging archives — see engines/ctunnel.conf; an all-engines re-pack needs
#   those staged or ctunnel fails loudly) · hysteria 2.14.0 · sing-box 1.14.4 ·
#   waterwall 1.6.0 · easytier 2.7.1
#
# RC10-PREP (13 cores): the overnight cores join — hysteria/sing-box (C),
# waterwall (C2+A4), easytier (D2) and the xray bump to v26.3.27 (A5, the
# hysteria2 carrier) are PASSTHROUGH packs (engines/*.conf PASSTHROUGH=1):
# the quantum-cores release asset IS the artifact — byte-identical to the
# ledger manifest digest (verify-engines.sh rail 2 holds by construction).
# easytier has NO registered driver yet (the D2 wiring spec is the next
# wave) — its pack is pre-staged so the R5 manifest serves it the moment
# the driver lands. naive is NOT packed: no core exists (the D2 hold —
# upstream's Chromium tags violate the cores tag contract; a human
# tag-exception is the unblock).
#
# wireguard uses the KERNEL module — no upstream binary; the packer states
# that in INDEX.md instead of silently skipping.
#
# Output: <outdir>/ with one folder per engine (the pack-engine.sh
# ready-to-upload layout) + INDEX.md + upload-all.sh (panel API, session
# login from a password FILE — never argv). Failed engines are recorded
# in INDEX.md and reported; the script exits non-zero if ANY failed.
###############################################################################
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: pack-all-engines.sh <outdir> [engine=version ...]}"; shift
# Default pinned versions (keep in sync with the drivers; overrides below).
declare -A VER=(
    [frp]=0.61.1 [backhaul]=0.7.2 [rathole]=0.5.0 [gost]=3.3.3
    [wstunnel]=10.1.9 [chisel]=1.10.1 [xray]=26.3.27 [udp2raw]=20230206.0 [ctunnel]=2.0.0
    [hysteria]=2.14.0 [sing-box]=1.14.4 [waterwall]=1.6.0 [easytier]=2.7.1
)
# Overrides from argv.
while [ $# -gt 0 ]; do
    v="${1#*=}"; k="${1%%=*}"
    VER["$k"]="$v"; shift
done
ORDER=(frp backhaul rathole gost wstunnel chisel xray udp2raw ctunnel hysteria sing-box waterwall easytier)

mkdir -p "$OUT"
FAILED=()
for E in "${ORDER[@]}"; do
    V="${VER[$E]}"
    echo "=== packing $E $V"
    if ENGINE_SIGNING_KEY="${ENGINE_SIGNING_KEY:-$HOME/.quantum-release/engine-signing.key}" \
        bash "$HERE/pack-engine.sh" "$E" "$V" --out "$OUT" > "$OUT/.log-$E" 2>&1; then
        echo "  ok"
    else
        echo "  FAILED (see $OUT/.log-$E)"
        FAILED+=("$E")
    fi
done

# INDEX.md
{
    echo "# Engine artifacts — $(date -u '+%Y-%m-%d')"
    echo
    echo "Signed with the engine-artifact ed25519 key (public half in each agent"
    echo "binary + in ENGINE-PUB-KEY.txt per engine). Upload via the panel Engines"
    echo "tab or with upload-all.sh (session login from a password FILE)."
    echo
    echo "| engine | version | arch | artifact | sha256 | signature | upload command |"
    echo "|---|---|---|---|---|---|---|"
    for E in "${ORDER[@]}"; do
        V="${VER[$E]}"
        D="$OUT/$E-$V-pack"
        if [ -d "$D" ]; then
            for A in amd64 arm64; do
                F="$D/$E-$V-linux-$A.tar.gz"
                [ -f "$F" ] || continue
                SHA="$(awk -v f="$(basename "$F")" '$2==f{print $1}' "$D/$(basename "$F").sha256")"
                echo "| $E | $V | $A | $(basename "$F") | $SHA | $(basename "$F").sig.b64 | \`upload-all.sh $E $A\` |"
            done
        else
            echo "| $E | $V | — | PACK FAILED (see .log-$E) | — | — | — |"
        fi
    done
    echo
    echo "wireguard: uses the KERNEL module — no upstream binary to pack."
} > "$OUT/INDEX.md"

# upload-all.sh — panel API with session login from a password FILE.
PANEL_URL="${PANEL_URL:-https://127.0.0.1:7443/<base>}"
PANEL_PASS_FILE="${PANEL_PASS_FILE:-/root/panel-password}"
{
    echo '#!/usr/bin/env bash'
    echo '# Upload every packed artifact to the panel (Engines tab API).'
    echo '# Login: username + password read from a FILE (never argv).'
    echo 'set -euo pipefail'
    echo 'PANEL="${PANEL_URL:-'"$PANEL_URL"'}"'
    echo 'PASS_FILE="${PANEL_PASS_FILE:-'"$PANEL_PASS_FILE"'}"'
    echo 'USER_FILE="${PANEL_USER_FILE:-/root/panel-user}"'
    echo 'CJ=$(mktemp); trap "rm -f $CJ" EXIT'
    echo 'PASS=$(cat "$PASS_FILE"); U=$(cat "$USER_FILE" 2>/dev/null || echo admin)'
    echo 'CSRF=$(curl -sk -c "$CJ" -X POST -H "Content-Type: application/json" \'
    echo '  -d "{\"username\":\"$U\",\"password\":\"$PASS\"}" "$PANEL/api/login" >/dev/null; '
    echo '  grep gre_csrf "$CJ" | awk "{print \$7}")'
    echo 'upload() { # engine version arch artifact sigb64file'
    echo '  local e=$1 v=$2 a=$3 f=$4 s=$5'
    echo '  curl -sk -b "$CJ" -H "X-CSRF-Token: $CSRF" -X POST "$PANEL/api/mesh/engines/artifacts" \'
    echo '    -F "engine=$e" -F "version=$v" -F "goarch=$a" -F "goos=linux" \'
    echo '    -F "name=$(basename "$f")" -F "signature=$(cat "$s")" -F "file=@$f"'
    echo '  echo'
    echo '}'
    for E in "${ORDER[@]}"; do
        V="${VER[$E]}"
        D="$OUT/$E-$V-pack"
        [ -d "$D" ] || continue
        for A in amd64 arm64; do
            F="$D/$E-$V-linux-$A.tar.gz"
            [ -f "$F" ] && echo "upload $E $V $A '$F' '$F.sig.b64'"
        done
    done
    echo 'echo "== manifest check =="'
    echo 'curl -sk "$PANEL/api/agent/engine-artifacts" | head -c 2000; echo'
} > "$OUT/upload-all.sh"
chmod +x "$OUT/upload-all.sh"

echo "== packed into $OUT (INDEX.md + upload-all.sh) =="
[ ${#FAILED[@]} -eq 0 ] && exit 0
echo "FAILED ENGINES: ${FAILED[*]}" >&2
exit 1
