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

VERSION="${1:?usage: build-release.sh <version> (e.g. v0.3.0)}"
case "$VERSION" in v[0-9]*) ;; *) echo "version must look like v0.3.0" >&2; exit 1;; esac

# Repo locations relative to this script: ../../quantum-{panel,agent}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACES="${QUANTUM_WORKSPACES:-$(cd "$RELEASE_ROOT/.." && pwd)}"
PANEL_REPO="${QUANTUM_PANEL_REPO:-$WORKSPACES/quantum-panel}"
AGENT_REPO="${QUANTUM_AGENT_REPO:-$WORKSPACES/quantum-agent}"

# INTEGRATION-DONE.md SHAs (update there first; overridable by env).
PANEL_SHA="${PANEL_SHA:-55a61bc23617}"
AGENT_SHA="${AGENT_SHA:-ba37723}"

SIGNING_KEY="${QUANTUM_SIGNING_KEY:-$HOME/.quantum-release/dev-signing.key}"
OUT="$RELEASE_ROOT/dist/quantum-bundle-$VERSION"
rm -rf "$OUT"; mkdir -p "$OUT/bin"

for tool in go git openssl python3; do command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool"; exit 1; }; done
[ -f "$SIGNING_KEY" ] || { echo "signing key missing: $SIGNING_KEY (generate: openssl genpkey -algorithm ed25519 -out $SIGNING_KEY)"; exit 1; }

checkout_sha() { # repo sha name
    git -C "$1" cat-file -t "$2" >/dev/null 2>&1 || {
        echo "fetching $3…"; git -C "$1" fetch origin main >/dev/null 2>&1; }
    git -C "$1" cat-file -t "$2" >/dev/null 2>&1 || { echo "SHA $2 not in $1 (fetch failed?)"; exit 1; }
}
checkout_sha "$PANEL_REPO" "$PANEL_SHA" quantum-panel
checkout_sha "$AGENT_REPO" "$AGENT_SHA" quantum-agent

build_one() { # repo sha module outname versionpkg
    local repo="$1" sha="$2" cmdpkg="$3" out="$4" vpkg="$5" arch="$6"
    local wt="$repo/.release-build"
    git -C "$repo" worktree add --detach "$wt" "$sha" >/dev/null 2>&1
    ( cd "$wt" && GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags "-s -w -X $cmdpkg.$vpkg=$VERSION" \
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
        "quantum-panel-linux-$arch" panel "$arch" || exit 1
    build_one "$AGENT_REPO" "$AGENT_SHA" ./cmd/quantum-agent \
        "quantum-agent-linux-$arch" agent "$arch" || exit 1
done

echo "== installers (copied as-is from the agent repo @ $AGENT_SHA) =="
git -C "$AGENT_REPO" show "$AGENT_SHA":install-agent.sh > "$OUT/install-agent.sh"
git -C "$AGENT_REPO" show "$AGENT_SHA":install-panel.sh  > "$OUT/install-panel.sh" 2>/dev/null \
    || echo "NOTE: install-panel.sh not in agent repo at this SHA" >&2
chmod +x "$OUT/install-agent.sh" "$OUT/install-panel.sh"

echo "== checksums + signatures =="
( cd "$OUT/bin" && sha256sum quantum-* | sort -k2 > checksums.txt )
sign() { openssl pkeyutl -sign -rawin -inkey "$SIGNING_KEY" -in "$1" -out "$1.sig"; }
( cd "$OUT/bin"
  for f in quantum-*; do sign "$f"; done
  sign checksums.txt )
openssl pkey -in "$SIGNING_KEY" -pubout -out "$OUT/signing-public.pem" 2>/dev/null

cat > "$OUT/README.txt" <<README
Quantum offline bundle $VERSION
Panel SHA: $PANEL_SHA  Agent SHA: $AGENT_SHA
Built: $(date -u '+%Y-%m-%dT%H:%MZ')

Contents: panel/agent binaries (linux amd64+arm64), the two installers,
sha256 checksums + ed25519 signatures, and this bundle's public signing key.

OFFLINE INSTALL (no GitHub access needed):
  1. copy this whole directory to the server (scp/USB)
  2. panel (foreign server):
       sudo bash install-panel.sh --binary bin/quantum-panel-linux-$(dpkg --print-architecture 2>/dev/null || echo amd64) \
            --checksum $(cd bin && sha256sum quantum-panel-linux-amd64 | cut -d' ' -f1) --generate-password
     (use the checksum matching YOUR architecture — see bin/checksums.txt)
  3. agent (each Iran/foreign server):
       sudo bash install-agent.sh --server https://<panel-host>:<port> \
            --token-file ./enroll-token --binary bin/quantum-agent-linux-<arch> \
            --checksum <sha256 from bin/checksums.txt> --ssh-port <your ssh port>
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
