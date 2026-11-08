#!/usr/bin/env bash
###############################################################################
# build-release.sh <version> — offline release bundle builder.
#
# Builds quantum-panel + quantum-agent (linux/amd64, linux/arm64 when the
# toolchain allows) from the INTEGRATION-DONE.md SHAs, signs everything
# with the local ed25519 dev key (NEVER in any repo), and packs
# quantum-bundle-<version>.zip:
#   bin/quantum-panel-linux-{amd64,arm64}
#   bin/quantum-agent-linux-{amd64,arm64}
#   bin/checksums.txt + bin/checksums.txt.sig
#   bin/quantum-panel-linux-<arch>.sig / quantum-agent-... .sig
#   install-agent.sh install-panel.sh        (copied as-is from agent repo)
#   signing-public.pem README.txt
#
# Requirements: go (>= 1.23), git, openssl, python3, curl|none (offline
# check only). The private key default: $HOME/.quantum-release/dev-signing.key
# (override QUANTUM_SIGNING_KEY). Run on Linux (WSL ok).
###############################################################################
set -euo pipefail

# GO-2026-66xx/6809: go1.23.4 stdlib (net/http, crypto/x509, mime/multipart)
# has known vulns fixed in 1.26.x — SECURITY-AUDIT-PANEL.md H2. Pin the
# toolchain so every release binary is built with the fixed stdlib.
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.26.9}"
# The toolchain module itself needs sumdb verification; private modules
# stay excluded via GOPRIVATE (set by the caller or below).
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
export GOPRIVATE="${GOPRIVATE:-github.com/Dark-modem/*}"
export GOFLAGS="${GOFLAGS:--mod=mod}"

VERSION="${1:?usage: build-release.sh <version> (e.g. v0.3.0)}"
case "$VERSION" in v[0-9]*) ;; *) echo "version must look like v0.3.0" >&2; exit 1;; esac

# Repo locations relative to this script: ../../quantum-{panel,agent}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACES="${QUANTUM_WORKSPACES:-$(cd "$RELEASE_ROOT/.." && pwd)}"
PANEL_REPO="${QUANTUM_PANEL_REPO:-$WORKSPACES/quantum-panel}"
AGENT_REPO="${QUANTUM_AGENT_REPO:-$WORKSPACES/quantum-agent}"

# INTEGRATION-DONE.md SHAs (update there first; overridable by env).
PANEL_SHA="${PANEL_SHA:-4e0611c9b28b}"
AGENT_SHA="${AGENT_SHA:-fb5a57aeb8b3}"

SIGNING_KEY="${QUANTUM_SIGNING_KEY:-$HOME/.quantum-release/dev-signing.key}"
OUT="$RELEASE_ROOT/dist/quantum-bundle-$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT/bin"

for tool in go git openssl python3; do command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool"; exit 1; }; done
[ -f "$SIGNING_KEY" ] || { echo "signing key missing: $SIGNING_KEY (generate: openssl genpkey -algorithm ed25519 -out $SIGNING_KEY)"; exit 1; }

# Engine-artifact signing key (RUNBOOK-FIXES item 14): the agent MUST pin
# the ed25519 public key (base64 DER SPKI) at build time — a build without
# it refuses every engine artifact (fail closed). Same default path and
# env override as scripts/pack-engine.sh so signed artifacts and pinned
# key always match. The key itself stays OUTSIDE every repo.
ENGINE_SIGNING_KEY="${QUANTUM_ENGINE_SIGNING_KEY:-$HOME/.quantum-release/engine-signing.key}"
ENGINE_DEV_NOTICE=""
if [ ! -f "$ENGINE_SIGNING_KEY" ]; then
    mkdir -p "$(dirname "$ENGINE_SIGNING_KEY")"
    openssl genpkey -algorithm ed25519 -out "$ENGINE_SIGNING_KEY" 2>/dev/null
    ENGINE_DEV_NOTICE=1
fi
ENGINE_PUB_B64="$(openssl pkey -in "$ENGINE_SIGNING_KEY" -pubout -outform DER 2>/dev/null | base64 -w0)"
if [ -n "$ENGINE_DEV_NOTICE" ]; then
    cat >&2 <<ENGINEWARN

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARNING: no engine-artifact signing key was found at
  $ENGINE_SIGNING_KEY
— a DEV key was generated. The agent binaries below pin the DEV public
key; engine artifacts signed by a production key WILL FAIL verification
on these binaries. Rebuild with the production key before any production
release (see docs/ENGINE-ARTIFACTS.md key ceremony).
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

ENGINEWARN
fi

checkout_sha() { # repo sha name
    git -C "$1" cat-file -t "$2" >/dev/null 2>&1 || {
        echo "fetching $3…"; git -C "$1" fetch origin main >/dev/null 2>&1; }
    git -C "$1" cat-file -t "$2" >/dev/null 2>&1 || { echo "SHA $2 not in $1 (fetch failed?)"; exit 1; }
}
checkout_sha "$PANEL_REPO" "$PANEL_SHA" quantum-panel
checkout_sha "$AGENT_REPO" "$AGENT_SHA" quantum-agent

build_one() { # repo sha module outname versionpkg arch [extra_ldflags]
    local repo="$1" sha="$2" cmdpkg="$3" out="$4" vpkg="$5" arch="$6" extra="${7:-}"
    local wt="$repo/.release-build"
    git -C "$repo" worktree add --detach "$wt" "$sha" >/dev/null 2>&1
    ( cd "$wt" && GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags "-s -w -X $cmdpkg.$vpkg=$VERSION $extra" \
        -o "$OUT/bin/$out" "$cmdpkg" 2>&1 | head -5 \
      || { echo "BUILD FAILED: $out ($arch)"; exit 1; } )
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
}

ARCHS="${RELEASE_ARCHS:-amd64 arm64}"
for arch in $ARCHS; do
    echo "== building linux/$arch =="
    if [ "$arch" = "arm64" ]; then
        go tool dist list | grep -q linux/arm64 || { echo "no arm64 in toolchain; skipping"; continue; }
    fi
    build_one "$PANEL_REPO" "$PANEL_SHA" ./cmd/quantum-panel \
        "quantum-panel-linux-$arch" main.panelVersion "$arch" || exit 1
    build_one "$AGENT_REPO" "$AGENT_SHA" ./cmd/quantum-agent \
        "quantum-agent-linux-$arch" github.com/Dark-modem/quantum-agent/internal/agent.panelVersion "$arch" \
        "-X github.com/Dark-modem/quantum-agent/internal/agent.engineArtifactPubKeyB64=$ENGINE_PUB_B64" || exit 1
done

echo "== engine-artifact public key (pinned into the agent binaries) =="
# The exact file the panel's engine-artifacts store expects
# (docs/ENGINE-ARTIFACTS.md: engine-artifacts/engine-pub.b64) — keeps the
# bundle self-consistent: what the binaries verify == what the store uses.
printf '%s\n' "$ENGINE_PUB_B64" > "$OUT/bin/engine-pub.b64"

echo "== installers (copied as-is from the agent repo @ $AGENT_SHA) =="
git -C "$AGENT_REPO" show "$AGENT_SHA":install-agent.sh > "$OUT/install-agent.sh"
git -C "$AGENT_REPO" show "$AGENT_SHA":install-panel.sh  > "$OUT/install-panel.sh" 2>/dev/null \
    || echo "NOTE: install-panel.sh not in agent repo at this SHA" >&2
chmod +x "$OUT/install-agent.sh" "$OUT/install-panel.sh"

echo "== checksums + signatures =="
( cd "$OUT/bin" && sha256sum quantum-* engine-pub.b64 | sort -k2 > checksums.txt )
sign() { openssl pkeyutl -sign -rawin -inkey "$SIGNING_KEY" -in "$1" -out "$1.sig"; }
( cd "$OUT/bin"
  for f in quantum-*; do sign "$f"; done
  sign checksums.txt )
openssl pkey -in "$SIGNING_KEY" -pubout -out "$OUT/signing-public.pem" 2>/dev/null

# RUNBOOK-FIXES items 1/17: the RELEASE-READY binary-hash table and the
# installer copy-paste commands MUST come from the shipped bundle's own
# checksums.txt (the signed source of truth) — hand-written tables went
# stale in rc2 and the installers (correctly) refused the hashes. This
# generated file is pasted verbatim into 00-ADMIN/RELEASE-READY.md.
echo "== RELEASE-READY hash material (generated from bin/checksums.txt) =="
PANEL_AMD="$(awk '$2=="quantum-panel-linux-amd64"{print $1}' "$OUT/bin/checksums.txt")"
PANEL_ARM="$(awk '$2=="quantum-panel-linux-arm64"{print $1}' "$OUT/bin/checksums.txt")"
AGENT_AMD="$(awk '$2=="quantum-agent-linux-amd64"{print $1}' "$OUT/bin/checksums.txt")"
AGENT_ARM="$(awk '$2=="quantum-agent-linux-arm64"{print $1}' "$OUT/bin/checksums.txt")"
cat > "$OUT/RELEASE-READY-HASHES.md" <<README2
<!-- GENERATED by scripts/build-release.sh from the shipped bin/checksums.txt
     (signed source of truth). Paste verbatim into RELEASE-READY.md.
     NEVER hand-edit hashes — rebuild instead. -->

## Binary checksums (from the shipped bundle's checksums.txt)

\`\`\`
$AGENT_AMD  quantum-agent-linux-amd64   (Iran x86_64)
$AGENT_ARM  quantum-agent-linux-arm64
$PANEL_AMD  quantum-panel-linux-amd64
$PANEL_ARM  quantum-panel-linux-arm64   (Germany ARM64)
\`\`\`

## Installer commands (hashes from the table above — never from memory)

Germany (ARM64, panel):
\`\`\`
sudo bash install-panel.sh --verify-only --binary bin/quantum-panel-linux-arm64 \\
    --checksum $PANEL_ARM
sudo bash install-panel.sh --binary bin/quantum-panel-linux-arm64 \\
    --checksum $PANEL_ARM --generate-password
\`\`\`

Iran (amd64, agent):
\`\`\`
sudo bash install-agent.sh --server https://<panel-host>:<port>/<base> \\
    --token-file ./enroll-token --binary bin/quantum-agent-linux-amd64 \\
    --checksum $AGENT_AMD --ssh-port <your ssh port>
\`\`\`

## Engine-artifact public key pinned into these agent binaries

bin/engine-pub.b64 (base64 DER SPKI — upload unchanged to the panel's
engine-artifacts store; artifacts signed with the matching private key):

\`\`\`
$ENGINE_PUB_B64
\`\`\`
README2

cat > "$OUT/README.txt" <<README
Quantum offline bundle $VERSION
Panel SHA: $PANEL_SHA  Agent SHA: $AGENT_SHA
Built: $(date -u '+%Y-%m-%dT%H:%MZ')

Contents: panel/agent binaries (linux amd64+arm64), the two installers,
sha256 checksums + ed25519 signatures, and this bundle's public signing key.

OFFLINE INSTALL (no GitHub access needed):
  1. copy this whole directory to the server (scp/USB)
  2. panel (foreign server): pick the checksum for YOUR architecture from
     bin/checksums.txt (signed — see VERIFY below), then:
       sudo bash install-panel.sh --binary bin/quantum-panel-linux-<arch> \
            --checksum <sha256 from bin/checksums.txt> --generate-password
  3. agent (each Iran/foreign server): pick your architecture's checksum
     from bin/checksums.txt, then:
       sudo bash install-agent.sh --server https://<panel-host>:<port>/<base> \
            --token-file ./enroll-token --binary bin/quantum-agent-linux-<arch> \
            --checksum <sha256 from bin/checksums.txt> --ssh-port <your ssh port>
  4. engine artifacts (frp/backhaul/…): upload bin/engine-pub.b64 to the
     panel's engine-artifacts store (same key the agent binaries pin).
VERIFY: openssl pkeyutl -verify -rawin -pubin -inkey signing-public.pem \
        -in bin/checksums.txt -sigfile bin/checksums.txt.sig
Architectures: uname -m  →  x86_64=amd64, aarch64=arm64
README
echo "== bundle: $OUT =="
ls -la "$OUT" "$OUT/bin"
python3 - "$OUT" "$RELEASE_ROOT/dist/quantum-bundle-$VERSION.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
if os.path.exists(dst): os.remove(dst)
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src))
print("zip:", dst, os.path.getsize(dst), "bytes")
PY
echo "DONE $VERSION"
