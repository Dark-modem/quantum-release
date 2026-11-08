#!/usr/bin/env bash
D=/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08
for e in backhaul rathole gost udp2raw; do
    echo "== $e:"
    tail -3 "$D/.log-$e" 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g" | head -3
done
