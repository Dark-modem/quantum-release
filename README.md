# quantum-release — offline release bundler

`scripts/build-release.sh <version>` builds quantum-panel + quantum-agent
(linux amd64+arm64) from the INTEGRATION-DONE.md SHAs, signs with the local
ed25519 dev key (`~/.quantum-release/dev-signing.key` — NEVER committed),
and packs `dist/quantum-bundle-<version>.zip` (bin/, installers,
checksums+signatures, signing-public.pem, README.txt).

Run on Linux/WSL:
```
QUANTUM_SIGNING_KEY=/path/to/dev-signing.key bash scripts/build-release.sh v0.3.0
```
Requires: go, git, openssl, python3. Env overrides: PANEL_SHA, AGENT_SHA,
QUANTUM_PANEL_REPO, QUANTUM_AGENT_REPO, RELEASE_ARCHS, PG_IMAGE_* n/a.
Docs: 00-ADMIN/RUNBOOK-FA.md (operator, Persian), 00-ADMIN/HANDOFF.md.

## v0.3.1 status (2026-11-05)

NOT built. The release gate (INTEGRATION-DONE.md "E2E: PASS") was not met:
the integration session recorded "E2E: FAIL 2026-11-05 netns e2e not
completed". v0.3.0 must not be deployed (pre-v2-hello agent, pre-phase2
panel). Rebuild with build-release.sh v0.3.1 once the gate turns green —
the SHAs to use are listed in INTEGRATION-DONE.md at that time.
