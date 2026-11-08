#!/usr/bin/env bash
tail -6 "/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/engines-2026-11-08/.log-udp2raw" | sed "s/\x1b\[[0-9;]*m//g"
