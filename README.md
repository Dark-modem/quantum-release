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
