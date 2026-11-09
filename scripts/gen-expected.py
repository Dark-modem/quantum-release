#!/usr/bin/env python3
# gen-expected.py — generates the EXPECTED values for the post-build
# verification FROM THE SOURCE at the announced SHAs (phase 14, never
# hand-written). Writes expected.json next to the bundle's buildinfo files.
# Usage: gen-expected.py <panel-repo> <panel-sha> <agent-repo> <agent-sha> <out-json>

import json, re, subprocess, sys

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
ENGNAME_MAP = {"Matrix": "matrix", "FRP": "frp", "Backhaul": "backhaul", "Xray": "xray",
               "Wg": "wireguard", "Wst": "wstunnel", "Chisel": "chisel", "Gost": "gost",
               "Rathole": "rathole", "Ctunnel": "ctunnel"}
asrc = src(agent_repo, agent_sha, "internal/agent/matrix_driver.go")
names = re.findall(r"reg\.Register\(New([A-Za-z]+)Driver\(\)\)", asrc)
engines = []
for cn in names:
    eid = ENGNAME_MAP.get(cn)
    if not eid:
        sys.exit("FATAL: registered driver %s has no id in ENGNAME_MAP — the source added a driver; add it" % cn)
    engines.append(eid)

# panel feature markers: the version_json.go buildFeatures list
vsrc = src(panel_repo, panel_sha, "internal/panel/version_json.go")
feats = re.findall(r'"([a-z0-9-]+)"', re.search(r"buildFeatures\(\) \[\]string ?\{(.*?)\}", vsrc, re.S).group(1))

json.dump({"migrations": migrations, "migration_versions": vers,
           "agent_engines": sorted(engines), "panel_features": feats},
          open(out, "w"), indent=1)
print("expected: migrations=%d engines=%s features=%s" % (migrations, ",".join(sorted(engines)), feats))
