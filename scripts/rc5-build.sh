#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/go/bin
export GOFLAGS=-mod=mod GOPRIVATE=github.com/Dark-modem/* GOPATH=$HOME/go
export GOTOOLCHAIN=go1.26.9 GOSUMDB=sum.golang.org
export PANEL_SHA=474ae3542ac30ae89a9af62217d7135bfed16436
export AGENT_SHA=ab0aef2043ea287d4dd9a7d3cd0b43c59fcc45b2
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release
bash scripts/build-release.sh v0.3.4-rc6 2>&1 | tail -25
