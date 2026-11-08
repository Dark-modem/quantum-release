#!/usr/bin/env bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/go/bin
cd /mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release
ENGINE_SIGNING_KEY=/mnt/c/Users/-Mahdi/quantum-release-keys/engine-signing.key bash -x scripts/pack-engine.sh backhaul 0.7.2 --out /tmp/dbg9-out 2>&1 | grep -aE "^\+ tar|^\+ ARC|^\+ SRC=|SUBSTITUT|empty|Cannot stat" | head -8
