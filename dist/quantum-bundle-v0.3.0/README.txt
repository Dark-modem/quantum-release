Quantum offline bundle v0.3.0
Panel SHA: 51e160235447  Agent SHA: 0f76219c81f8

OFFLINE INSTALL (no GitHub access needed):
  1. copy this directory to the server (scp/USB)
  2. panel: sudo bash install-panel.sh --binary bin/quantum-panel-linux-<arch> --checksum <see bin/checksums.txt> --generate-password
  3. agent: sudo bash install-agent.sh --server https://<panel>:<port> --token-file ./enroll-token --binary bin/quantum-agent-linux-<arch> --checksum <see bin/checksums.txt> --ssh-port <ssh port>
  arch: uname -m (x86_64=amd64, aarch64=arm64)
VERIFY signature:
  openssl pkeyutl -verify -rawin -pubin -inkey signing-public.pem -in bin/checksums.txt -sigfile bin/checksums.txt.sig
Example panel checksum (amd64): 6ebc9e8a0d7f7ae055508bce1ec8cf4becb9d6cfc3d31242582fd1ab1cf3636c
