#!/usr/bin/env bash
# post-build-verify.sh — PHASE 14 release blocker (RUNBOOK-FIXES 25/31).
# Runs the built linux/amd64 binaries and asserts their self-reported
# provenance against (a) the requested SHAs, (b) the expected engine set
# GENERATED FROM THE SOURCE at that SHA (never hand-written), (c) the
# migration count from the source, (d) known feature markers. Exits
# non-zero loudly on any mismatch — a bundle that cannot prove it was
# built from the announced SHA must never ship (PHASE8-ACCEPTANCE).
#
# Usage: post-build-verify.sh <bundle-bin-dir> <panel-sha> <agent-sha> <agent-repo>
set -uo pipefail

BIN_DIR="${1:?usage: post-build-verify.sh <bin-dir> <panel-sha> <agent-sha> <agent-repo>}"
PANEL_SHA="${2:?}"
AGENT_SHA="${3:?}"
AGENT_REPO="${4:?}"

json_get() { # json field  (extracts a scalar string/number from our own
            # fixed-format version --json output; no jq dependency)
    grep -o "\"$1\": *[^,}]*" | head -1 | sed 's/.*: *//; s/^"//; s/"$//'
}

fail() { echo "FATAL: $*" >&2; exit 1; }

# ---- expected agent engine set: GENERATED from the source at AGENT_SHA ----
# grep every Register call in NewAgentEngines and map the constructor name
# to the driver id mechanically. A NEW registered driver produces an
# unmapped name and the verification FAILS until the map gains the id —
# the source, not a hand-written list, drives the expectation.
ENGNAME_MAP="Matrix:matrix FRP:frp Backhaul:backhaul Xray:xray Wg:wireguard Wst:wstunnel Chisel:chisel Gost:gost Rathole:rathole"
EXPECT_AGENT_ENGINES=""
for CN in $(git -C "$AGENT_REPO" show "$AGENT_SHA":internal/agent/matrix_driver.go \
        | grep -oE 'reg\.Register\(New[A-Za-z]+Driver\(\)\)' \
        | sed -E "s/reg\.Register\(New([A-Za-z]+)Driver\(\)\)/\1/" | sort -u); do
    ID="$(printf '%s\n' "$ENGNAME_MAP" | tr ' ' '\n' | grep "^$CN:" | cut -d: -f2)"
    if [ -z "$ID" ]; then
        fail "registered driver $CN has no id in ENGNAME_MAP — the source added a driver; add the id to the map"
    fi
    EXPECT_AGENT_ENGINES="$EXPECT_AGENT_ENGINES,$ID"
done
EXPECT_AGENT_ENGINES="${EXPECT_AGENT_ENGINES#,}"
EXPECT_AGENT_SORTED="$(printf '%s\n' "$EXPECT_AGENT_ENGINES" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
echo "expected agent engines (from source @ $AGENT_SHA): $EXPECT_AGENT_SORTED"

# ---- expected panel migration count: GENERATED from the source ------------
EXPECT_PANEL_MIGRATIONS="$(git -C "$PANEL_REPO" show "$PANEL_SHA":internal/store/store.go \
    | awk '/var migrations = \[\]string\{/,/^}/' | grep -cE '^\t`')"
echo "expected panel migrations (from source @ $PANEL_SHA): $EXPECT_PANEL_MIGRATIONS"

verify_bin() { # bin sha want_engines_sorted want_migrations is_agent is_panel
    local bin="$1" want_sha="$2" want_engines="$3" want_migrations="$4" is_agent="$5" is_panel="$6"
    local name
    name="$(basename "$bin")"
    echo "== post-build verify: $name =="
    chmod +x "$bin" 2>/dev/null || fail "cannot chmod $bin"

    local vj
    if ! vj="$("$bin" version --json 2>/dev/null)"; then
        fail "$name version --json failed to run"
    fi
    local got_sha got_ver got_mig got_engines
    got_sha="$(printf '%s' "$vj" | json_get sha)"
    got_ver="$(printf '%s' "$vj" | json_get version)"
    got_mig="$(printf '%s' "$vj" | json_get migrations)"
    got_engines="$(printf '%s' "$vj" | json_get engines | sed 's/^\[//; s/\]$//; s/"//g; s/, /,/g; s/,/,/g' | tr -d ' ' | sed 's/,$//')"

    [ "$got_sha" = "$want_sha" ] || fail "$name sha = $got_sha, want $want_sha"
    [ "$got_ver" = "$VERSION" ] || fail "$name version = $got_ver, want $VERSION"

    if [ "$is_agent" = "1" ]; then
        local sorted_got
        sorted_got="$(printf '%s\n' "$(echo "$got_engines" | tr ',' '\n')" | sort | tr '\n' ',' | sed 's/,$//')"
        [ "$sorted_got" = "$want_engines" ] || fail "$name engines [$sorted_got] != source set [$want_engines]"
        local m
        for m in wstunnel chisel rathole udp2raw gost xray wireguard; do
            strings "$bin" | grep -q "$m" || fail "$name missing driver marker $m"
        done
        if strings "$bin" | grep -q "60-quantum-hardening.conf"; then
            fail "$name still carries the removed 60- hardening drop-in (stale tree)"
        fi
    fi
    if [ "$is_panel" = "1" ]; then
        [ "$got_mig" = "$want_migrations" ] || fail "$name migrations = $got_mig, want $want_migrations"
        local m
        for m in mesh-wizard quantum-mesh.css engine-artifacts; do
            strings "$bin" | grep -q "$m" || fail "$name missing marker $m (stale tree)"
        done
    fi
    echo "   post-build verify OK"
}

PANEL_AMD="$BIN_DIR/quantum-panel-linux-amd64"
AGENT_AMD="$BIN_DIR/quantum-agent-linux-amd64"
[ -f "$PANEL_AMD" ] || fail "missing $PANEL_AMD"
[ -f "$AGENT_AMD" ] || fail "missing $AGENT_AMD"

PANEL_ENG="-"
verify_bin "$PANEL_AMD" "$PANEL_SHA" "$PANEL_ENG" "$EXPECT_PANEL_MIGRATIONS" 0 1
verify_bin "$AGENT_AMD" "$AGENT_SHA" "$EXPECT_AGENT_SORTED" "-" 1 0

# arm64 cannot run on an amd64 host: assert the version stamp statically.
for f in "$BIN_DIR/quantum-panel-linux-arm64" "$BIN_DIR/quantum-agent-linux-arm64"; do
    [ -f "$f" ] || continue
    if strings "$f" | grep -q "$VERSION"; then
        echo "   arm64 static marker OK: $(basename "$f")"
    else
        fail "$(basename "$f") lacks the version stamp $VERSION"
    fi
done

echo "== post-build verification PASSED =="
