# RELEASE-REQUESTS — release session → repo owners

1. **install-agent.sh / install-panel.sh (quantum-agent):** move
   `need_systemd` AFTER binary checksum verification, or add a
   `--verify-only` mode. Today `need_systemd` runs first, so a bad
   `--checksum` on a systemd-less box reports "systemd is required"
   instead of the checksum mismatch — offline verification cannot be
   tested without systemd.
2. **install-panel.sh:** fix shellcheck SC2015 (`A && B || C` on the
   hardened-unit check, line ~345) and SC2016 (single-quoted strings).
3. **both installers:** on checksum mismatch print expected vs got sha256
   (currently just an error line).
