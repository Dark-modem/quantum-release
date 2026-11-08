#!/usr/bin/env bash
for e in backhaul rathole gost chisel xray udp2raw; do
    echo "== $e:"
    tail -3 "/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08/.log-$e" 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g" | head -3
done
