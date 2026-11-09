D=/mnt/c/Users/-Mahdi/Downloads/Quantum/01-REPOSITORIES/quantum-release/dist/quantum-bundle-v0.3.4-rc6
cp $D/bin/quantum-panel-linux-amd64 /tmp/qp-ver && chmod 755 /tmp/qp-ver
/tmp/qp-ver version 2>/dev/null || /tmp/qp-ver --version 2>/dev/null || echo "no version flag"
cp $D/bin/quantum-agent-linux-amd64 /tmp/qa-ver && chmod 755 /tmp/qa-ver
/tmp/qa-ver version 2>/dev/null || /tmp/qa-ver --version 2>/dev/null || echo "agent: no version flag"
strings /tmp/qp-ver | grep -o "v0\.3\.3[^ ]*" | head -2
