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
# BACKEND-27 (rc7 dry-run): a *-dryrun name runs the FULL pipeline (build,
# post-build verify, MANIFEST, zip) but is explicitly NOT a release — it
# exists to prove the pipeline and expose blockers before the real rc7.
# Everything release-specific keeps failing closed for real v* names.
case "$VERSION" in
    *-dryrun) DRYRUN=1 ;;
    v[0-9]*)  DRYRUN=0 ;;
    *) echo "version must look like v0.3.0 (real release) or <name>-dryrun (pipeline dry-run)" >&2; exit 1;;
esac
if [ "$DRYRUN" = 1 ]; then
    cat >&2 <<DRYWARN
#######################################################################
# DRY-RUN: $VERSION is NOT a release. Do not tag, do not publish,     #
# do not upload these artifacts anywhere — pipeline verification only. #
#######################################################################
DRYWARN
fi

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

build_one() { # repo sha module outname versionpkg shaPkg timePkg arch [extra_ldflags]
    # PHASE 14 (RUNBOOK-FIXES 25/31): the old version silenced `worktree add`
    # failures (>/dev/null 2>&1) and the subshell's `exit 1` never propagated
    # (the trailing `worktree remove || true` became the return status) — a
    # stale `.release-build` tree then built OLD code under a FRESH version
    # stamp, which is exactly how RC3/RC4 shipped binaries that did not
    # match their announced SHAs (PHASE8-ACCEPTANCE). Every step below is
    # fatal, and the checked-out tree is PROVEN before the build runs.
    local repo="$1" sha="$2" cmdpkg="$3" out="$4" vpkg="$5" shaPkg="$6" timePkg="$7" arch="$8" extra="${9:-}"
    local wt="$repo/.release-build"

    # 1. no stale worktree may survive from an aborted run
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    rm -rf "$wt"
    if [ -e "$wt" ]; then
        echo "FATAL: cannot clear the stale build tree $wt" >&2
        return 1
    fi

    # 2. add the detached worktree — LOUD (no redirect hides a failure)
    if ! git -C "$repo" worktree add --detach "$wt" "$sha"; then
        echo "FATAL: git worktree add failed for $repo @ $sha" >&2
        return 1
    fi

    # 3. PROVE the tree: HEAD must equal the requested SHA… (normalize BOTH
    #    to full commit form: a short requested SHA would otherwise fail the
    #    string comparison against rev-parse's full output)
    local got
    got="$(git -C "$wt" rev-parse HEAD)"
    sha="$(git -C "$repo" rev-parse "$sha^{commit}")"
    if [ "$got" != "$sha" ]; then
        echo "FATAL: worktree HEAD $got != requested $sha for $out" >&2
        git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
        return 1
    fi
    # …and no MODIFIED tracked files (no +dirty in the buildinfo, ever)
    # no MODIFIED tracked files (a fresh detached worktree cannot carry
    # modifications; untracked junk like a stray C:/ dir from a mispath'd
    # tool does not affect the build — the HEAD assertion above is what
    # pins the content).
    if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]; then
        echo "FATAL: worktree for $repo @ $sha has MODIFIED tracked files:" >&2
        git -C "$wt" status --porcelain --untracked-files=no | head -5 >&2
        git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
        return 1
    fi

    # 4. build with the full provenance stamps (version/SHA/time; the Go
    #    version is runtime.Version() read by the binary itself)
    local gover build_time
    gover="$(go version | awk '{print $3}')"
    build_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if ! ( cd "$wt" && GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags "-s -w \
            -X $vpkg=$VERSION \
            -X $shaPkg=$sha \
            -X $timePkg=$build_time \
            $extra" \
        -o "$OUT/bin/$out" "$cmdpkg" ); then
        echo "FATAL: BUILD FAILED: $out ($arch)" >&2
        git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
        return 1
    fi
    if [ ! -f "$OUT/bin/$out" ]; then
        echo "FATAL: compiler reported success but $out is missing" >&2
        return 1
    fi

    # 5. record the stamps for the post-build verification + MANIFEST
    {
        echo "arch=$arch"
        echo "sha=$sha"
        echo "build_time=$build_time"
        echo "go_version=$gover"
        echo "version=$VERSION"
    } > "$OUT/bin/$out.buildinfo"

    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
}

ARCHS="${RELEASE_ARCHS:-amd64 arm64}"
for arch in $ARCHS; do
    echo "== building linux/$arch =="
    if [ "$arch" = "arm64" ]; then
        go tool dist list | grep -q linux/arm64 || { echo "no arm64 in toolchain; skipping"; continue; }
    fi
    build_one "$PANEL_REPO" "$PANEL_SHA" ./cmd/quantum-panel \
        "quantum-panel-linux-$arch" \
        github.com/Dark-modem/quantum-panel/internal/panel.panelVersion \
        github.com/Dark-modem/quantum-panel/internal/panel.buildSHA \
        github.com/Dark-modem/quantum-panel/internal/panel.buildTime \
        "$arch" || exit 1
    build_one "$AGENT_REPO" "$AGENT_SHA" ./cmd/quantum-agent \
        "quantum-agent-linux-$arch" \
        github.com/Dark-modem/quantum-agent/internal/agent.panelVersion \
        github.com/Dark-modem/quantum-agent/internal/agent.buildSHA \
        github.com/Dark-modem/quantum-agent/internal/agent.buildTime \
        "$arch" \
        "-X github.com/Dark-modem/quantum-agent/internal/agent.engineArtifactPubKeyB64=$ENGINE_PUB_B64" || exit 1
done

echo "== engine-artifact public key (pinned into the agent binaries) =="
# The exact file the panel's engine-artifacts store expects
# (docs/ENGINE-ARTIFACTS.md: engine-artifacts/engine-pub.b64) — keeps the
# bundle self-consistent: what the binaries verify == what the store uses.
printf '%s\n' "$ENGINE_PUB_B64" > "$OUT/bin/engine-pub.b64"
echo "engine-key pin fingerprint: $(printf '%s' "$ENGINE_PUB_B64" | sha256sum | awk '{print substr($1,1,16)}') (build-release.sh — pack-engine.sh must print the SAME)"

# PHASE 14: post-build verification runs as a separate script (see
# post-build-verify.sh) — it runs the built binaries and asserts their
# provenance; a failure exits the release loudly.
export VERSION PANEL_REPO AGENT_REPO PANEL_SHA AGENT_SHA OUT
# generate the EXPECTED values from the source at the announced SHAs
( python3 "$(dirname "${BASH_SOURCE[0]}")/gen-expected.py" "$PANEL_REPO" "$PANEL_SHA" "$AGENT_REPO" "$AGENT_SHA" "$OUT/bin/expected.json" ) || exit 1
( bash "$(dirname "${BASH_SOURCE[0]}")/post-build-verify.sh" "$OUT/bin" "$PANEL_SHA" "$AGENT_SHA" "$AGENT_REPO" ) || exit 1

echo "== installers (copied as-is from the agent repo @ $AGENT_SHA) =="
git -C "$AGENT_REPO" show "$AGENT_SHA":install-agent.sh > "$OUT/install-agent.sh"
git -C "$AGENT_REPO" show "$AGENT_SHA":install-panel.sh  > "$OUT/install-panel.sh" 2>/dev/null \
    || echo "NOTE: install-panel.sh not in agent repo at this SHA" >&2
chmod +x "$OUT/install-agent.sh" "$OUT/install-panel.sh"

# RUNBOOK-FIXES items 1/17: the RELEASE-READY binary-hash table and the
# installer copy-paste commands MUST come from the shipped bundle's own
# checksums.txt (the signed source of truth) — hand-written tables went
# stale in rc2 and the installers (correctly) refused the hashes. This
# generated file is pasted verbatim into 00-ADMIN/RELEASE-READY.md.
echo "== RELEASE-READY hash material (generated from the built binaries) =="
PANEL_AMD="$(sha256sum "$OUT/bin/quantum-panel-linux-amd64" | awk '{print $1}')"
PANEL_ARM="$(sha256sum "$OUT/bin/quantum-panel-linux-arm64" | awk '{print $1}')"
AGENT_AMD="$(sha256sum "$OUT/bin/quantum-agent-linux-amd64" | awk '{print $1}')"
AGENT_ARM="$(sha256sum "$OUT/bin/quantum-agent-linux-arm64" | awk '{print $1}')"
cat > "$OUT/RELEASE-READY-HASHES.md" <<README2
<!-- GENERATED by scripts/build-release.sh from the built binaries (the same
     values the signed bin/checksums.txt carries). Paste verbatim into RELEASE-READY.md.
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

echo "== checksums + signatures =="
( cd "$OUT/bin" && sha256sum quantum-* engine-pub.b64 expected.json \
      ../install-agent.sh ../install-panel.sh ../README.txt ../RELEASE-READY-HASHES.md \
      | sort -k2 > checksums.txt )
sign() { openssl pkeyutl -sign -rawin -inkey "$SIGNING_KEY" -in "$1" -out "$1.sig"; }
( cd "$OUT/bin"
  for f in quantum-*; do sign "$f"; done
  sign checksums.txt )
openssl pkey -in "$SIGNING_KEY" -pubout -out "$OUT/signing-public.pem" 2>/dev/null


# ============================================================================
# PHASE 14 — MANIFEST.json: the signed provenance document inside the bundle
# (RUNBOOK-FIXES 25/31). It records the announced SHAs, the binaries'
# self-reported provenance (version --json), the generated engine set, the
# migration count, sizes, sha256s, build host and time — everything an
# operator (or session 3) needs to prove the bundle matches its announcement.
# The file is signed with the release key; verify-bundle.sh checks it.
# ============================================================================
echo "== MANIFEST.json: signed provenance document =="
vj_capture() { # <binary> <outfile> — the MANIFEST is built from the binaries'
              # OWN self-report; a failed capture must stop the build loudly
              # (a silent one shipped the rc3/rc4 provenance lie).
  local bin="$1" out="$2"
  if ! "$bin" version --json > "$out"; then
    echo "FATAL: $(basename "$bin") version --json failed — MANIFEST would be built without provenance" >&2
    exit 1
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" || {
    echo "FATAL: $(basename "$bin") version --json did not emit valid JSON" >&2
    exit 1
  }
}
vj_capture "$OUT/bin/quantum-panel-linux-amd64" /tmp/.rc-panel-vj.json
vj_capture "$OUT/bin/quantum-agent-linux-amd64" /tmp/.rc-agent-vj.json
MANIFEST="$OUT/MANIFEST.json"
PANEL_AMD="$(awk '$2=="quantum-panel-linux-amd64"{print $1}' "$OUT/bin/checksums.txt")"
PANEL_ARM="$(awk '$2=="quantum-panel-linux-arm64"{print $1}' "$OUT/bin/checksums.txt")"
AGENT_AMD="$(awk '$2=="quantum-agent-linux-amd64"{print $1}' "$OUT/bin/checksums.txt")"
AGENT_ARM="$(awk '$2=="quantum-agent-linux-arm64"{print $1}' "$OUT/bin/checksums.txt")"
for __s in "$PANEL_AMD" "$PANEL_ARM" "$AGENT_AMD" "$AGENT_ARM"; do
  [ "$__s" ] && [ ${#__s} -eq 64 ] || {
    echo "FATAL: checksums.txt is missing a 64-hex sha256 for a binary (got '$__s') — MANIFEST refused" >&2
    exit 1
  }
done
PANEL_BINFO="$OUT/bin/quantum-panel-linux-amd64.buildinfo"
AGENT_BINFO="$OUT/bin/quantum-agent-linux-amd64.buildinfo"
BUILD_HOST="$(hostname)"
BUILD_HOST_USER="$(whoami)"
# The protocol SHA is GENERATED from the pinned go.mod pseudo-versions — not
# passed by hand (a hand-fed SHA is how rc3/rc4 announced code they did not
# contain). Panel and agent must pin the SAME protocol commit.
PROTO_PANEL="$(git -C "$PANEL_REPO" show "$PANEL_SHA":go.mod \
  | awk '/github.com\/Dark-modem\/quantum-protocol v/ {n=split($2,a,"-"); print a[n]}')"
PROTO_AGENT="$(git -C "$AGENT_REPO" show "$AGENT_SHA":go.mod \
  | awk '/github.com\/Dark-modem\/quantum-protocol v/ {n=split($2,a,"-"); print a[n]}')"
if [ -z "$PROTO_PANEL" ] || [ -z "$PROTO_AGENT" ]; then
  echo "FATAL: could not extract the quantum-protocol SHA from go.mod (panel='$PROTO_PANEL' agent='$PROTO_AGENT')" >&2
  exit 1
fi
# BACKEND-27: the guard stays FATAL for every real release. A *-dryrun may
# proceed ONLY with an explicit second opt-in (QUANTUM_ALLOW_PROTOCOL_MISMATCH=1)
# and then RECORDS the mismatch in the MANIFEST so it cannot hide (the rc7
# dry-run needs this: panel main pins 9b9a27c, agent main still pins 244d10f
# until DEV-AGENT bumps it — that blocker is exactly what the dry-run reports).
PROTO_PIN_MISMATCH=0
if [ "$PROTO_PANEL" != "$PROTO_AGENT" ]; then
  if [ "$DRYRUN" = 1 ] && [ "${QUANTUM_ALLOW_PROTOCOL_MISMATCH:-0}" = "1" ]; then
    echo "DRY-RUN WARNING: panel and agent pin DIFFERENT protocol commits (panel=$PROTO_PANEL agent=$PROTO_AGENT)" >&2
    echo "  proceeding ONLY because this is a *-dryrun with QUANTUM_ALLOW_PROTOCOL_MISMATCH=1;" >&2
    echo "  a REAL release (v*) still fails closed here until the pins match." >&2
    PROTO_PIN_MISMATCH=1
  else
    echo "FATAL: panel and agent pin DIFFERENT protocol commits (panel=$PROTO_PANEL agent=$PROTO_AGENT)" >&2
    echo "       (a *-dryrun may proceed with QUANTUM_ALLOW_PROTOCOL_MISMATCH=1 — never a real release)" >&2
    exit 1
  fi
fi
PROTOCOL_SHA="$(git -C "$PANEL_REPO/../quantum-protocol" rev-parse "${PROTO_PANEL}^{commit}" 2>/dev/null || echo "$PROTO_PANEL")"
# The expected engine set / migration count come from ONE place: expected.json,
# generated from source by gen-expected.py earlier in this script. A second
# hand-maintained copy here is exactly the class of drift the phase-8
# acceptance caught — so the MANIFEST asserts self-report == generated.
EXPECTED_FILE="$OUT/bin/expected.json"
[ -s "$EXPECTED_FILE" ] || { echo "FATAL: $EXPECTED_FILE missing — gen-expected.py did not run" >&2; exit 1; }
python3 - "$MANIFEST" "$EXPECTED_FILE" <<PYMAN
import json, os, sys, subprocess

out = sys.argv[1]
expected = json.load(open(sys.argv[2]))
panel_amd = "$PANEL_AMD"; panel_arm = "$PANEL_ARM"
agent_amd = "$AGENT_AMD"; agent_arm = "$AGENT_ARM"

def binfo(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            k, _, v = line.strip().partition('=')
            if v: d[k] = v
    return d

pj = json.loads(open('/tmp/.rc-panel-vj.json').read()) if os.path.exists('/tmp/.rc-panel-vj.json') else {}
aj = json.loads(open('/tmp/.rc-agent-vj.json').read()) if os.path.exists('/tmp/.rc-agent-vj.json') else {}

# The binaries' OWN self-report must equal what the source generates. A
# mismatch means a stale/wrong tree got this far — refuse to write a
# MANIFEST that would bless it (this is the phase-8 lie, made impossible).
mismatch = []
if aj.get("engines") != expected["agent_engines"]:
    mismatch.append("agent engines: self-report %s != generated %s" % (aj.get("engines"), expected["agent_engines"]))
if pj.get("migrations") != expected["migrations"]:
    mismatch.append("panel migrations: self-report %s != generated %s" % (pj.get("migrations"), expected["migrations"]))
if pj.get("features") != expected["panel_features"]:
    mismatch.append("panel features: self-report %s != generated %s" % (pj.get("features"), expected["panel_features"]))
if mismatch:
    sys.stderr.write("FATAL: binary self-report disagrees with source-generated expectations — MANIFEST refused\n")
    for m in mismatch:
        sys.stderr.write("  - " + m + "\n")
    sys.exit(1)

man = {
  "manifest_version": 1,
  "release": "$VERSION",
  "built_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "build_host": "$BUILD_HOST",
  "built_by": "$BUILD_HOST_USER",
  "go_version": "$(go version | awk '{print $3}')",
  "sources": {
    "panel": {"sha": "$PANEL_SHA", "repo": "github.com/Dark-modem/quantum-panel"},
    "agent": {"sha": "$AGENT_SHA", "repo": "github.com/Dark-modem/quantum-agent"},
    "protocol": {"sha": "${PROTOCOL_SHA:-unknown}", "repo": "github.com/Dark-modem/quantum-protocol",
                 "panel_pin": "$PROTO_PANEL", "agent_pin": "$PROTO_AGENT",
                 "pin_mismatch": "$PROTO_PIN_MISMATCH"}
  },
  "binaries": {
    "quantum-panel-linux-amd64": {"sha256": "$PANEL_AMD", "size": os.path.getsize("$OUT/bin/quantum-panel-linux-amd64"), "build": binfo("$PANEL_BINFO")},
    "quantum-panel-linux-arm64": {"sha256": "$PANEL_ARM", "size": os.path.getsize("$OUT/bin/quantum-panel-linux-arm64"), "build": binfo("$PANEL_BINFO")},
    "quantum-agent-linux-amd64": {"sha256": "$AGENT_AMD", "size": os.path.getsize("$OUT/bin/quantum-agent-linux-amd64"), "build": binfo("$AGENT_BINFO")},
    "quantum-agent-linux-arm64": {"sha256": "$AGENT_ARM", "size": os.path.getsize("$OUT/bin/quantum-agent-linux-arm64"), "build": binfo("$AGENT_BINFO")}
  },
  "panel_version": pj.get("version", "$VERSION"),
  "panel_migrations": pj.get("migrations"),
  "panel_flags": pj.get("flags", {}),
  "panel_features": pj.get("features", []),
  "agent_version": aj.get("version", "$VERSION"),
  "agent_engines": aj.get("engines", []),
  "expected_agent_engines": expected["agent_engines"],
  "engine_artifact_key_sha256": "$(printf '%s' "$ENGINE_PUB_B64" | sha256sum | awk '{print $1}')",
  "engine_key_pin_fingerprint": "$(printf '%s' "$ENGINE_PUB_B64" | sha256sum | awk '{print substr($1,1,16)}')"
}
json.dump(man, open(out, 'w'), indent=2, sort_keys=True)
print('MANIFEST.json written')
PYMAN
sign "$MANIFEST"
echo "   MANIFEST.json signed (self-report == generated expectations)"
grep -E '"release"|"panel"|"agent"' "$MANIFEST" | head -4

# RELEASE-READY lines are GENERATED from the signed MANIFEST — no
# hand-written hashes (RUNBOOK-FIXES 31). The engines folder is announced
# via ENGINES_DIR (default: the dated dir pack-all-engines.sh last wrote);
# its artifacts must verify against the SAME key the agent binaries pin —
# scripts/verify-engines.sh <dir> does that check.
ENGINES_DIR="${ENGINES_DIR:-dist/engines-2026-11-09}"
[ -d "$RELEASE_ROOT/$ENGINES_DIR" ] || { echo "FATAL: ENGINES_DIR $RELEASE_ROOT/$ENGINES_DIR does not exist" >&2; exit 1; }
# BACKEND-27: the label used to be hardcoded "RC6:" — the rc7 build would
# have announced itself as RC6. Derive it from the version instead.
case "$VERSION" in
    *-rc[0-9]*) RC_LABEL="RC${VERSION##*-rc}" ;;
    *-dryrun)   RC_LABEL="RC-DRAFT" ;;
    *)          RC_LABEL="RC-LINE" ;;
esac
RC_LINE="$(python3 - "$MANIFEST" "$ENGINES_DIR" <<PYRC
import json, sys
m = json.load(open(sys.argv[1]))
print("$RC_LABEL: dist/quantum-bundle-{}.zip <zip-sha256> protocol {} panel {} agent {} engines {}".format(
    m["release"], m["sources"]["protocol"]["sha"], m["sources"]["panel"]["sha"],
    m["sources"]["agent"]["sha"], sys.argv[2]))
PYRC
)"
printf '%s\n' "$RC_LINE" > "$OUT/RC-LINE.txt"
echo "RC line (for RELEASE-READY.md): $RC_LINE"


ls -la "$OUT" "$OUT/bin"
python3 - "$OUT" "$RELEASE_ROOT/dist/quantum-bundle-$VERSION.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
wrap = os.path.basename(src)  # entries live under ONE top dir so extraction is clean
if os.path.exists(dst): os.remove(dst)
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            if f == "RC-LINE.txt":
                continue  # a zip cannot contain its own hash — the final RC
                          # line ships NEXT TO the zip instead (see below)
            full = os.path.join(root, f)
            z.write(full, os.path.join(wrap, os.path.relpath(full, src)))
print("zip:", dst, os.path.getsize(dst), "bytes")
PY
# The RC line is the release announcement — its zip hash must be the REAL
# hash of the zip that now exists, never a placeholder (RUNBOOK-FIXES 31).
# It is written next to the zip (operators verify-bundle.sh the zip and the
# line together) and refreshed in the unzipped bundle dir.
ZIP_SHA="$(sha256sum "$RELEASE_ROOT/dist/quantum-bundle-$VERSION.zip" | awk '{print $1}')"
python3 - "$OUT/RC-LINE.txt" "$ZIP_SHA" \
    "$RELEASE_ROOT/dist/quantum-bundle-$VERSION.RC-LINE.txt" <<'PYRCL'
import sys
path, zsha, sib = sys.argv[1], sys.argv[2], sys.argv[3]
line = open(path).read().strip()
assert "<zip-sha256>" in line, "RC-LINE.txt has no zip-hash placeholder — refused to blind-edit"
final = line.replace("<zip-sha256>", zsha) + "\n"
open(path, "w").write(final)
open(sib, "w").write(final)
print("RC line (final, zip hash filled in):", final.strip())
PYRCL
echo "DONE $VERSION"
