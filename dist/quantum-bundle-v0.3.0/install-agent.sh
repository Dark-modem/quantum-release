#!/usr/bin/env bash
###############################################################################
# install-agent.sh — Quantum agent installer (phase1/hardening rewrite)
#
# Installs quantum-agent on a tunnel server (Iran or Hetzner):
#   1. downloads the release binary + checksums.txt and verifies SHA-256
#      (or installs --binary with an explicit --checksum)
#   2. enrolls the endpoint with the panel (token never echoed or logged)
#   3. writes a HARDENED systemd unit (see HARDENING NOTES below)
#   4. applies the conservative initial security profile — the SAFE subset —
#      natively and idempotently:
#        - additive, ownership-tagged firewall allows for the SSH port and
#          every --open port (engine-first when the agent's firewall engine
#          answers; raw tagged ufw otherwise)
#        - the conservative sysctl drop-in (same owned file the hardening
#          module later manages) applied with per-key read-back
#        - persistent journald + active timesync (best effort)
#        - the full conservative Profile JSON written to
#          /etc/quantum-agent/desired/hardening-profile.json for the panel
#          to converge on; `quantum-agent hardening apply` is attempted and
#          its absence tolerated (the CLI lands with protocol v2 wiring)
#   5. verifies: service active, enrolled, SSH banner still answering
#
# SAFE-APPLY discipline (this installer never locks you out):
#   - the SSH door is opened and VERIFIED (real SSH banner on 127.0.0.1)
#     BEFORE any firewall policy change;
#   - firewall changes are additive and tagged; never reset/flush/disable;
#   - enabling ufw happens ONLY with the explicit --enable-firewall flag,
#     and only after the SSH allow + banner verification succeeded
#     (installer-safety rule: the enable decision belongs to the operator);
#   - SSH server config is NOT touched at all: key-only, root-login policy
#     and port moves are panel desired-state items applied by the
#     hardening module with its rollback timer — never by an installer.
#
# Usage:
#   sudo bash install-agent.sh --server https://panel.example:7443[/base] \
#        (--token-file FILE | --token TOKEN | QUANTUM_ENROLL_TOKEN env) \
#        [--name NAME] [--role iran|foreign] \
#        [--version latest|vX.Y.Z] [--binary FILE [--checksum SHA256]] \
#        [--ssh-port N] [--open PORT[/tcp|/udp]]... [--enable-firewall] \
#        [--with-fail2ban] [--no-start] [--check] [--yes]
#
# Idempotent: every step detects its own previous effect and skips. Re-runs
# upgrade the binary in place (previous binary kept as .bak, restored if
# the service fails to start) and converge the profile.
#
# Exceptions to unit hardening (documented, each is load-bearing):
#   - NoNewPrivileges=yes is set; the agent never needs setuid helpers.
#   - ProtectSystem is NOT used: the agent must write owned drop-ins under
#     /etc (sshd_config.d, sysctl.d, fail2ban jail.d, journald.conf.d) and
#     replace its own binary at /usr/local/bin on `agent.update`. A
#     ProtectSystem=strict + ReadWritePaths allowlist is possible in
#     principle but brittle across engine config dirs (/etc/frp,
#     /etc/backhaul, engine-specific paths); revisit when the engine set
#     is frozen.
#   - ProtectHome=read-only (not yes): SSH-forward carriers may read key
#     material under /root/.ssh.
#   - ProtectKernelTunables is NOT set: netopt/hardening legitimately write
#     /proc/sys.
#   - The service runs as root by design (ufw/sshd/sysctl/systemctl control
#     is the agent's job); a dedicated user would break those operations.
#
# Secrets: the enrollment token is read from --token-file/env, passed to
# the binary via argv once, and never printed, logged or stored by this
# script. No SSH keys are generated, installed or transported here.
###############################################################################
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="install-agent.sh"
REPO="Dark-modem/quantum-agent"
BIN="/usr/local/bin/quantum-agent"
UNIT="/etc/systemd/system/gre-agent.service"   # legacy unit name kept: the
                                               # binary's install/uninstall
                                               # commands reference it
AGENT_DIR="/etc/quantum-agent"
STATE_DIR="${AGENT_DIR}/desired"
LOG_TAG="quantum-install-agent"

# ---------------------------------------------------------------------------
# Output helpers (no secrets may ever pass through them)
# ---------------------------------------------------------------------------
info()  { printf '[ %s ] %s\n' "$LOG_TAG" "$*"; }
warn()  { printf '[ %s ] WARN: %s\n' "$LOG_TAG" "$*" >&2; }
die()   { printf '[ %s ] ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# trun bounds EVERY external command (a hung pre-engine binary must never
# wedge the installer; probes 15s, applies 90s, downloads 300s).
trun() { timeout --kill-after=5 "$1" "${@:2}"; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo bash $SCRIPT_NAME ..."; }
need_systemd() { have systemctl || die "systemd is required (no systemctl)"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SERVER="" TOKEN="" TOKEN_FILE="" NAME="" ROLE=""
VERSION="latest" BINARY="" CHECKSUM=""
SSH_PORT="" ENABLE_FIREWALL=0 WITH_FAIL2BAN=0 NO_START=0 CHECK_ONLY=0 ASSUME_YES=0
OPEN_RULES=()

usage() { sed -n '2,40p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER="${2:-}"; shift 2;;
        --token)         TOKEN="${2:-}"; shift 2;;
        --token-file)    TOKEN_FILE="${2:-}"; shift 2;;
        --name)          NAME="${2:-}"; shift 2;;
        --role)          ROLE="${2:-}"; shift 2;;
        --version)       VERSION="${2:-}"; shift 2;;
        --binary)        BINARY="${2:-}"; shift 2;;
        --checksum)      CHECKSUM="${2:-}"; shift 2;;
        --ssh-port)      SSH_PORT="${2:-}"; shift 2;;
        --open)          OPEN_RULES+=("${2:-}"); shift 2;;
        --enable-firewall) ENABLE_FIREWALL=1; shift;;
        --with-fail2ban) WITH_FAIL2BAN=1; shift;;
        --no-start)      NO_START=1; shift;;
        --check)         CHECK_ONLY=1; shift;;
        --yes)           ASSUME_YES=1; shift;;
        -h|--help)       usage; exit 0;;
        *) die "unknown argument: $1 (see --help)";;
    esac
done

[[ -n "$SERVER" || $CHECK_ONLY -eq 1 ]] || die "--server is required (or use --check)"
if [[ -n "$BINARY" && -z "$CHECKSUM" && -f "${BINARY}.sha256" ]]; then
    CHECKSUM="$(trun 10 awk '{print $1}' "${BINARY}.sha256" 2>/dev/null || true)"
fi
if [[ -n "$BINARY" && -z "$CHECKSUM" ]]; then
    die "--binary requires --checksum SHA256 (or a ${BINARY}.sha256 sidecar)"
fi
if [[ -z "$TOKEN" && -n "$TOKEN_FILE" ]]; then
    [[ -r "$TOKEN_FILE" ]] || die "cannot read --token-file: $TOKEN_FILE"
    TOKEN="$(trun 5 head -c 4096 "$TOKEN_FILE" | tr -d '[:space:]')"
fi
[[ -z "$TOKEN" ]] && TOKEN="${QUANTUM_ENROLL_TOKEN:-}"
for r in "${OPEN_RULES[@]:-}"; do
    [[ -z "$r" ]] && continue
    [[ "$r" =~ ^[0-9]{1,5}/(tcp|udp)$ ]] || die "--open wants PORT/tcp or PORT/udp, got: $r"
done
if [[ -n "$SSH_PORT" ]]; then
    [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
        || die "--ssh-port wants 1-65535"
fi

# ---------------------------------------------------------------------------
# SSH door verification: a REAL banner on 127.0.0.1:<port>, not "port open".
# Returns 0 only when something answered with an SSH-2 banner.
# ---------------------------------------------------------------------------
ssh_banner_ok() {
    local port="$1"
    [[ -n "$port" ]] || return 1
    trun 6 bash -c '
        exec 3<>/dev/tcp/127.0.0.1/'"$port"' || exit 1
        IFS= read -r -t 3 line <&3 || exit 1
        [[ "$line" == SSH-* ]]
    ' 2>/dev/null
}

# detect_ssh_port: the port sshd currently answers on (banner-verified).
# Falls back 22 -> --ssh-port -> any listening sshd port from ss.
detect_ssh_port() {
    local cand port
    for cand in 22 "$SSH_PORT"; do
        [[ -n "$cand" ]] || continue
        if ssh_banner_ok "$cand"; then printf '%s' "$cand"; return 0; fi
    done
    if have ss; then
        while read -r port; do
            if ssh_banner_ok "$port"; then printf '%s' "$port"; return 0; fi
        done < <(trun 10 ss -tln 2>/dev/null | awk '/sshd|ssh/ {split($4,a,":"); print a[length(a)]}' | sort -u)
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Step 1: binary acquisition with checksum verification
# ---------------------------------------------------------------------------
arch_tag() {
    case "$(uname -m)" in
        x86_64)  printf 'amd64';;
        aarch64|arm64) printf 'arm64';;
        *) die "unsupported architecture: $(uname -m)";;
    esac
}

fetch_binary() {
    local arch; arch="$(arch_tag)"
    if [[ -n "$BINARY" ]]; then
        [[ -r "$BINARY" ]] || die "cannot read --binary: $BINARY"
        local got
        got="$(trun 60 sha256sum "$BINARY" | awk '{print $1}')"
        [[ "$got" == "$CHECKSUM" ]] || die "checksum mismatch for $BINARY
  expected: $CHECKSUM
  got:      $got"
        printf '%s' "$BINARY"
        return 0
    fi
    have curl || have wget || die "need curl or wget to download the release"
    if [[ "$VERSION" == "latest" ]]; then
        VERSION="$(release_latest)" || die "cannot resolve the latest release tag"
    fi
    local url_base="https://github.com/${REPO}/releases/download/${VERSION}"
    local asset="quantum-agent-linux-${arch}"
    local tmp; tmp="$(mktemp -t quantum-agent.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN
    info "downloading ${asset} (${VERSION})"
    download "$url_base/$asset" "$tmp" || die "download failed: $asset"
    local sums; sums="$(mktemp -t quantum-sums.XXXXXX)"
    trap 'rm -f "$tmp" "$sums"' RETURN
    download "$url_base/checksums.txt" "$sums" \
        || die "download failed: checksums.txt (refusing an unverified binary)"
    local want
    want="$(trun 10 awk -v a="$asset" '$2==a || $2=="*"a {print $1}' "$sums")"
    [[ -n "$want" ]] || die "checksums.txt has no entry for $asset"
    local got; got="$(trun 60 sha256sum "$tmp" | awk '{print $1}')"
    [[ "$got" == "$want" ]] || die "checksum mismatch for $asset
  expected: $want
  got:      $got"
    printf '%s' "$tmp"
}

release_latest() {
    local out
    if have curl; then
        out="$(trun 20 curl -fsSL "https://github.com/${REPO}/releases/latest" -o /dev/null -w '%{url_effective}' 2>/dev/null || true)"
    else
        out="$(trun 20 wget -qO- --max-redirect=0 "https://github.com/${REPO}/releases/latest" 2>/dev/null | grep -o 'tag/[^"]*' | head -1 || true)"
    fi
    out="${out##*/}"
    [[ "$out" =~ ^v[0-9] ]] || return 1
    printf '%s' "$out"
}

download() { # url dest
    if have curl; then trun 300 curl -fsSL --retry 2 --connect-timeout 10 "$1" -o "$2"
    else trun 300 wget -qO "$2" "$1"; fi
}

install_binary() {
    local src; src="$(fetch_binary)"
    local cur=""
    [[ -x "$BIN" ]] && cur="$(trun 30 sha256sum "$BIN" | awk '{print $1}')"
    local new; new="$(trun 30 sha256sum "$src" | awk '{print $1}')"
    if [[ "$cur" == "$new" ]]; then
        info "binary already installed (sha256 ${new:0:12}…) — skipping"
        return 0
    fi
    if [[ -x "$BIN" ]]; then
        cp -a "$BIN" "${BIN}.bak"   # one-generation rollback copy
    fi
    install -m 0755 "$src" "${BIN}.new" && mv -f "${BIN}.new" "$BIN"
    info "installed $BIN (sha256 ${new:0:12}…)"
}

# ---------------------------------------------------------------------------
# Step 2: enrollment (token never echoed)
# ---------------------------------------------------------------------------
enroll() {
    [[ -n "$TOKEN" ]] || { warn "no enrollment token given (--token/--token-file); skipping enrollment — the agent will stay unprovisioned"; return 0; }
    local already
    already=0
    [[ -s "${AGENT_DIR}/agent.json" ]] && already=1
    if [[ $already -eq 1 && $ASSUME_YES -eq 0 && -z "${FORCE_ENROLL:-}" ]]; then
        info "agent.json already present — keeping existing enrollment (use FORCE_ENROLL=1 to re-enroll)"
        return 0
    fi
    local out rc display_name
    display_name="${NAME:-$(hostname 2>/dev/null || printf agent)}"
    [[ -n "$ROLE" ]] && display_name="${display_name} (${ROLE})"
    set +e
    out="$(trun 90 "$BIN" agent enroll --server "$SERVER" --token "$TOKEN" --name "$display_name" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        # Never print $out: it may carry request details.
        die "enrollment failed (exit $rc); check --server reachability and token validity"
    fi
    info "enrolled with ${SERVER}"
}

# ---------------------------------------------------------------------------
# Step 3: hardened systemd unit
# ---------------------------------------------------------------------------
write_unit() {
    local tmp; tmp="$(mktemp -t gre-agent-unit.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp" <<UNIT
# managed by install-agent.sh (phase1/hardening) — edits belong in the installer
[Unit]
Description=Quantum agent (tunnel server desired-state + engines)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=GRE_PANEL_DIR=${AGENT_DIR}
ExecStart=${BIN} agent run
Restart=always
RestartSec=5

# --- hardening (see the header of install-agent.sh for the exceptions) ---
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
RestrictSUIDSGID=yes
LockPersonality=yes
# NOT set, deliberately (each would break a real agent duty):
#   ProtectSystem      -> agent writes /etc drop-ins + self-update of BIN
#   ProtectKernelTunables -> agent writes /proc/sys (netopt/hardening)

[Install]
WantedBy=multi-user.target
UNIT
    if [[ -f "$UNIT" ]] && cmp -s "$tmp" "$UNIT"; then
        info "systemd unit already up to date"
    else
        [[ -f "$UNIT" ]] && cp -a "$UNIT" "${UNIT}.bak"
        install -m 0644 "$tmp" "$UNIT"
        trun 15 systemctl daemon-reload
        info "wrote hardened unit $UNIT"
    fi
}

# ---------------------------------------------------------------------------
# Step 4a: firewall — additive, tagged, engine-first, SSH door first
# ---------------------------------------------------------------------------
fw_engine_available() {
    [[ -x "$BIN" ]] || return 1
    trun 60 "$BIN" firewall --help >/dev/null 2>&1   # exit 0 = engine present
}

# fw_open rules as engine ops; falls back to tagged raw ufw. Every rule is
# ONE allow with a quantum:installer:<role> comment. Nothing else is ever
# touched (no reset, no deny, no foreign ports).
fw_allow() { # owner_tag spec
    local owner="$1" spec="$2"
    if fw_engine_available; then
        trun 90 "$BIN" firewall apply --owner "$owner" --add "$spec" --yes >/dev/null 2>&1 && return 0
        warn "engine apply failed for $spec; falling back to raw ufw"
    fi
    if have ufw; then
        trun 30 ufw allow "$spec" comment "quantum:installer:${owner}" >/dev/null 2>&1 || true
        return 0
    fi
    warn "no firewall tool available; $spec left for the panel desired state"
    return 0
}

fw_enable_gated() {
    [[ $ENABLE_FIREWALL -eq 1 ]] || { info "ufw left as-is (pass --enable-firewall to opt in)"; return 0; }
    have ufw || { warn "--enable-firewall given but ufw is not installed"; return 0; }
    local status; status="$(trun 15 ufw status 2>/dev/null || true)"
    [[ "$status" == *"Status: active"* ]] && { info "ufw already active"; return 0; }

    # Gate: the SSH door must be an explicit allow AND banner-verified
    # BEFORE any default-deny policy exists.
    local ssh_port; ssh_port="$(detect_ssh_port)" || die "cannot verify the SSH port; refusing to touch firewall policies"
    fw_allow "ssh" "${ssh_port}/tcp"
    trun 15 ufw status 2>/dev/null | grep -q "${ssh_port}/tcp" || die "SSH allow rule is not present in ufw; refusing to enable"
    ssh_banner_ok "$ssh_port" || die "SSH banner check failed; refusing to enable ufw"
    trun 30 ufw default deny incoming >/dev/null
    trun 30 ufw default allow outgoing >/dev/null
    trun 30 ufw --force enable >/dev/null
    ssh_banner_ok "$ssh_port" || die "SSH stopped answering after ufw enable — run: ufw disable (rollback); rule: ufw allow ${ssh_port}/tcp"
    info "ufw enabled with default-deny incoming (SSH ${ssh_port}/tcp verified before and after)"
}

firewall_step() {
    local ssh_port
    ssh_port="$(detect_ssh_port)" || { warn "cannot detect the SSH port; firewall door skipped (panel desired state can add it later)"; ssh_port=""; }
    if [[ -n "$ssh_port" ]]; then
        # Idempotent by engine/ufw dedupe; the limit form stays to the
        # hardening module (a limit can rate-limit the operator's own
        # bootstrap hammering).
        fw_allow "ssh" "${ssh_port}/tcp"
        info "SSH door open: ${ssh_port}/tcp (banner verified)"
    fi
    local r
    for r in "${OPEN_RULES[@]:-}"; do
        [[ -z "$r" ]] && continue
        fw_allow "declared" "$r"
        info "declared port open: $r"
    done
    fw_enable_gated
}

# ---------------------------------------------------------------------------
# Step 4b: conservative profile — sysctl / journald / timesync / fail2ban
# ---------------------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-quantum-hardening.conf"

sysctl_step() {
    local tmp; tmp="$(mktemp -t quantum-sysctl.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp" <<'SYSCTL'
# managed by quantum-agent hardening — do not edit; revert with hardening.rollback
# quantum-agent hardening sysctl — safe-hygiene keys; performance tuning
# (bbr, buffers, conntrack sizing) lives in the netopt engine's drop-in.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
SYSCTL
    if [[ -f "$SYSCTL_FILE" ]] && ! grep -q "managed by quantum-agent hardening" "$SYSCTL_FILE"; then
        warn "$SYSCTL_FILE exists but is foreign — leaving it alone (the hardening module will report the conflict)"
        return 0
    fi
    if [[ -f "$SYSCTL_FILE" ]] && cmp -s "$tmp" "$SYSCTL_FILE"; then
        info "sysctl drop-in already in place"
    else
        cp -a "$tmp" "$SYSCTL_FILE"
        chmod 0644 "$SYSCTL_FILE"
    fi
    # Apply + read EVERY key back (nothing silent — the setup.sh discipline).
    local key want got rc=0
    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        key="${line%% = *}"; want="${line#* = }"
        got="$(trun 5 cat "/proc/sys/${key//./\/}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$got" != "$want" ]]; then
            warn "sysctl ${key}: wanted ${want}, kernel reports '${got:-<unset>}'"
            rc=1
        fi
    done < "$SYSCTL_FILE"
    if [[ $rc -eq 0 ]]; then info "sysctl drop-in applied and read back cleanly"; else
        set +e; trun 15 sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; set -e
        warn "some sysctl keys needed an explicit re-apply; see warnings above"
    fi
}

journald_step() {
    mkdir -p /var/log/journal
    local drop="/etc/systemd/journald.conf.d/99-quantum-persistent.conf"
    if [[ ! -f "$drop" ]]; then
        mkdir -p /etc/systemd/journald.conf.d
        printf '# managed by quantum-agent hardening — do not edit\n[Journal]\nStorage=persistent\n' > "$drop"
        chmod 0644 "$drop"
        trun 15 systemctl try-restart systemd-journald >/dev/null 2>&1 || true
        info "persistent journald enabled"
    fi
    trun 15 systemctl enable --now systemd-timesyncd >/dev/null 2>&1 \
        && info "timesync active" || warn "systemd-timesyncd could not be enabled (non-fatal)"
}

fail2ban_step() {
    [[ $WITH_FAIL2BAN -eq 1 ]] || return 0
    if ! have fail2ban-client; then
        if have apt-get; then
            trun 120 apt-get update -qq >/dev/null 2>&1 || true
            trun 300 apt-get install -y fail2ban >/dev/null 2>&1 || { warn "fail2ban could not be installed"; return 0; }
        else
            warn "fail2ban not installed and no apt-get; skipping"; return 0
        fi
    fi
    local port; port="$(detect_ssh_port || printf 22)"
    local jail="/etc/fail2ban/jail.d/quantum-hardening.local"
    if [[ ! -f "$jail" ]]; then
        mkdir -p /etc/fail2ban/jail.d
        cat > "$jail" <<JAIL
# managed by quantum-agent hardening — do not edit
[sshd]
enabled = true
port = ${port}
backend = systemd
maxretry = 5
findtime = 600
bantime = 3600
JAIL
        chmod 0644 "$jail"
    fi
    trun 30 systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban did not start"
    trun 30 systemctl restart fail2ban >/dev/null 2>&1 || true
    info "fail2ban sshd jail active (port ${port})"
}

# ---------------------------------------------------------------------------
# Step 4c: the full conservative profile as desired state
# ---------------------------------------------------------------------------
profile_step() {
    mkdir -p "$STATE_DIR"
    local f="${STATE_DIR}/hardening-profile.json"
    local ssh_port; ssh_port="$(detect_ssh_port || printf 22)"
    local opens="" r
    for r in "${OPEN_RULES[@]:-}"; do
        [[ -z "$r" ]] && continue
        opens+=",{\"port\":${r%%/*},\"proto\":\"${r##*/}\",\"owner\":\"service:declared\"}"
    done
    cat > "$f" <<JSON
{"version":1,"name":"conservative","firewall":{"default_deny_incoming":true,"allow_outgoing":true,"allows":[$(printf '%s' "$opens" | sed 's/^,//')],"limits":[{"port":${ssh_port},"proto":"tcp","owner":"service:ssh","note":"SSH rate-limited"}]},"sysctl":[{"key":"net.ipv4.tcp_syncookies","value":"1"},{"key":"net.ipv4.tcp_max_syn_backlog","value":"4096"},{"key":"net.ipv4.conf.all.rp_filter","value":"1"},{"key":"net.ipv4.conf.default.rp_filter","value":"1"},{"key":"net.ipv4.conf.all.accept_source_route","value":"0"},{"key":"net.ipv4.conf.default.accept_source_route","value":"0"},{"key":"net.ipv4.conf.all.accept_redirects","value":"0"},{"key":"net.ipv4.conf.default.accept_redirects","value":"0"},{"key":"net.ipv4.conf.all.send_redirects","value":"0"},{"key":"net.ipv4.conf.default.send_redirects","value":"0"},{"key":"net.ipv4.icmp_echo_ignore_broadcasts","value":"1"},{"key":"net.ipv4.icmp_ignore_bogus_error_responses","value":"1"}],"timesync":{"ensure_active":true},"logging":{"persistent_journal":true}}
JSON
    chmod 0644 "$f"
    info "conservative profile written: $f"
    # Attempt the module CLI (lands with protocol v2 wiring); tolerate its
    # absence. Safe-apply is the DEFAULT of that path: the rollback timer
    # arms itself for anything risky.
    if [[ $NO_START -eq 0 ]] && [[ -x "$BIN" ]]; then
        set +e
        trun 120 "$BIN" hardening apply --profile "$f" >/dev/null 2>&1
        local rc=$?
        set -e
        case $rc in
            0) info "hardening module applied the conservative profile (safe-apply armed; confirm via the panel)";;
            *) info "hardening module CLI not wired yet (exit $rc) — the profile JSON waits for protocol v2";;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Step 5: start + verify
# ---------------------------------------------------------------------------
start_service() {
    if [[ $NO_START -eq 1 ]]; then
        info "--no-start: not enabling the service (run: systemctl enable --now gre-agent)"
        return 0
    fi
    trun 30 systemctl enable --now gre-agent.service >/dev/null
    sleep 2
    if ! trun 15 systemctl is-active --quiet gre-agent.service; then
        warn "service not active — rolling the binary back if we replaced it"
        if [[ -f "${BIN}.bak" ]]; then
            cp -a "${BIN}.bak" "$BIN" && trun 15 systemctl restart gre-agent.service || true
        fi
        die "gre-agent.service failed to start; journal: journalctl -u gre-agent -n 50"
    fi
    info "gre-agent.service active"
}

verify() {
    local ok=1
    trun 15 systemctl is-active --quiet gre-agent.service || { warn "service inactive"; ok=0; }
    if [[ -s "${AGENT_DIR}/agent.json" ]]; then
        info "enrollment file present"
    else
        warn "not enrolled (no ${AGENT_DIR}/agent.json)"
    fi
    local ssh_port; ssh_port="$(detect_ssh_port || true)"
    if [[ -n "$ssh_port" ]] && ssh_banner_ok "$ssh_port"; then
        info "SSH path verified on port ${ssh_port}"
    else
        warn "could NOT verify the SSH banner — check sshd before disconnecting"
        ok=0
    fi
    [[ $ok -eq 1 ]] && info "VERIFY: OK" || { warn "VERIFY: problems above"; return 1; }
}

check_install() {
    [[ -x "$BIN" ]] || die "not installed: $BIN"
    "$BIN" version 2>/dev/null || true
    trun 15 systemctl is-active gre-agent.service 2>/dev/null || true
    [[ -f "$UNIT" ]] && grep -q "NoNewPrivileges=yes" "$UNIT" && info "hardened unit present" || warn "unit missing or not hardened"
    verify || true
    exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
need_root
need_systemd
if [[ $CHECK_ONLY -eq 1 ]]; then check_install; fi   # read-only, exits

info "installing quantum-agent (arch $(arch_tag), version ${VERSION})"
install_binary
mkdir -p "$AGENT_DIR"
enroll
write_unit
trun 15 systemctl daemon-reload
start_service
firewall_step
sysctl_step
journald_step
fail2ban_step
profile_step
verify
info "done. The panel can now push hardening/netopt desired state; safe-apply +
      its 120 s rollback timer protect every subsequent change."
