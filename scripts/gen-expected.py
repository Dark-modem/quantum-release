#!/usr/bin/env python3
# gen-expected.py — generates the EXPECTED values for the post-build
# verification FROM THE SOURCE at the announced SHAs (phase 14, never
# hand-written). Writes expected.json next to the bundle's buildinfo files.
# Usage: gen-expected.py <panel-repo> <panel-sha> <agent-repo> <agent-sha> <out-json>
#
# CORES-2 LEDGER MOVE: the derived engine-id list is cross-checked against
# the Dark-modem/quantum-cores MANIFEST.json files — the CANONICAL ledger
# of external engine cores. Every mapped engine id must be an exempt
# in-process/kernel engine (matrix = ships with the agent binary, wireguard
# = host kernel module; documented in the ledger README "Exemptions") or
# have a <id>/MANIFEST.json in the ledger — anything else is FATAL (a new
# engine without a published core must stop the pipeline here).
# LEDGER SOURCE (least fragile, by CORES-2 decision): a LOCAL clone only,
# no network at run time — $QUANTUM_CORES_DIR, else the sibling
# ../quantum-cores of this repo (the 01-REPOSITORIES workspace layout).
# A missing ledger is FATAL unless QUANTUM_ALLOW_NO_CORES_LEDGER=1 — the
# documented downgrade (legacy expected-list in use, ledger rail OFF, loud
# warning; runner scripts for builds from WSL-side clones must set
# QUANTUM_CORES_DIR accordingly). Rail 1 below (fatal on unmapped driver
# NAMES) stays active in every mode — it is in-repo by design.

import json, os, re, subprocess, sys

panel_repo, panel_sha, agent_repo, agent_sha, out = sys.argv[1:6]

def src(repo, sha, path):
    return subprocess.run(["git", "-C", repo, "show", sha + ":" + path],
                          capture_output=True, text=True, check=True).stdout

# panel migrations: count the backtick string literals in the migrations var
psrc = src(panel_repo, panel_sha, "internal/store/store.go")
m = re.search(r"var migrations = \[\]string\{(.*?)\n\}", psrc, re.S)
if not m:
    sys.exit("FATAL: migrations var not found in the panel source at " + panel_sha)
block = m.group(1)
migrations = len(re.findall(r"^\t`", block, re.M))
vers = re.findall(r"// (\d+):", block)

# agent engines: every Register call in NewAgentEngines, mapped mechanically
# (RAIL 1 — fatal on unmapped driver names; preserved verbatim per CORES-2).
# RC10-PREP: the overnight drivers join — Hysteria + Singbox (AGENT-31) and
# Waterwall (OVERNIGHT-A5, the 18-method node-chain driver); 13 registrations.
ENGNAME_MAP = {"Matrix": "matrix", "FRP": "frp", "Backhaul": "backhaul", "Xray": "xray",
               "Wg": "wireguard", "Wst": "wstunnel", "Chisel": "chisel", "Gost": "gost",
               "Rathole": "rathole", "Ctunnel": "ctunnel", "Hysteria": "hysteria",
               "Singbox": "singbox", "Waterwall": "waterwall"}
asrc = src(agent_repo, agent_sha, "internal/agent/matrix_driver.go")
names = re.findall(r"reg\.Register\(New([A-Za-z]+)Driver\(\)\)", asrc)
engines = []
for cn in names:
    eid = ENGNAME_MAP.get(cn)
    if not eid:
        sys.exit("FATAL: registered driver %s has no id in ENGNAME_MAP — the source added a driver; add it" % cn)
    engines.append(eid)

# CORES-2 LEDGER MOVE (RAIL 2): every mapped engine id must exist in the
# quantum-cores ledger — <id>/MANIFEST.json — unless exempt (see header).
# RC10-PREP alias: a DRIVER id may differ from the cores repo FOLDER name —
# the sing-box core carries the dash, the agent's engine id does not (same
# alias the panel's cores resolution uses since BACKEND-45).
LEDGER = os.environ.get("QUANTUM_CORES_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "quantum-cores")
LEDGER_ALIAS = {"singbox": "sing-box"}
EXEMPT = ("matrix", "wireguard")
if os.path.isdir(LEDGER):
    unledgered = [e for e in set(engines)
                  if e not in EXEMPT
                  and not os.path.isfile(os.path.join(LEDGER, LEDGER_ALIAS.get(e, e), "MANIFEST.json"))]
    if unledgered:
        sys.exit("FATAL: engines without a quantum-cores ledger manifest: %s — pack + publish the core (tag <core>-vX.Y.Z in Dark-modem/quantum-cores) before shipping" % ", ".join(sorted(unledgered)))
    print("ledger: engine ids all covered by %s" % os.path.abspath(LEDGER))
elif os.environ.get("QUANTUM_ALLOW_NO_CORES_LEDGER") == "1":
    print("WARNING: LEDGER SKIPPED — no quantum-cores clone at %s and QUANTUM_ALLOW_NO_CORES_LEDGER=1: legacy expected-list in use, ledger rail OFF" % LEDGER,
          file=sys.stderr)
else:
    sys.exit("FATAL: quantum-cores ledger not found at %s — set QUANTUM_CORES_DIR to a clone of https://github.com/Dark-modem/quantum-cores (public) or keep it as the sibling ../quantum-cores of this repo, or set QUANTUM_ALLOW_NO_CORES_LEDGER=1 (documented downgrade: ledger check skipped)" % LEDGER)

# panel feature markers: the version_json.go buildFeatures list
vsrc = src(panel_repo, panel_sha, "internal/panel/version_json.go")
feats = re.findall(r'"([a-z0-9-]+)"', re.search(r"buildFeatures\(\) \[\]string ?\{(.*?)\}", vsrc, re.S).group(1))

json.dump({"migrations": migrations, "migration_versions": vers,
           "agent_engines": sorted(engines), "panel_features": feats},
          open(out, "w"), indent=1)
print("expected: migrations=%d engines=%s features=%s" % (migrations, ",".join(sorted(engines)), feats))
