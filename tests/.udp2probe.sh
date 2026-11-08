#!/usr/bin/env bash
for tag in 20230206.0 v20230206.0; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -L "https://github.com/wangyu-/udp2raw/releases/download/$tag/udp2raw_binaries.tar.gz")
    echo "$tag -> $code"
done
