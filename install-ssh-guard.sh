#!/usr/bin/env bash
#
# install.sh — SSH Discord Notifier + Auto-Block installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash
#
#   Non-interactive:
#   curl -fsSL .../install.sh | sudo \
#     WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy" \
#     AUTO_BLOCK=true FAIL_THRESHOLD=5 FAIL_WINDOW=600 \
#     bash
#
# Installs:
#   /etc/ssh-guard/config.conf                 (shared settings, webhook URL)
#   /usr/local/bin/ssh-discord-notify.sh       (watches journal, notifies, auto-blocks)
#   /usr/local/bin/block-ip.sh                 (manual/automatic IP block/unblock)
#   /etc/systemd/system/ssh-discord-notify.service
#
set -euo pipefail

# ---------- must be root ----------
if [[ "${EUID}" -ne 0 ]]; then
  echo "This installer must be run as root (try: sudo bash install.sh)" >&2
  exit 1
fi

# ---------- dependencies ----------
for bin in curl systemctl journalctl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Required command '$bin' not found. This installer targets systemd-based Linux distros." >&2
    exit 1
  fi
done

if ! command -v ufw >/dev/null 2>&1 && ! command -v firewall-cmd >/dev/null 2>&1 \
   && ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
  echo "No supported firewall tool found (ufw, firewalld, nft, or iptables)." >&2
  echo "The notifier will still work, but auto-block/block-ip.sh will not." >&2
fi

prompt() {
  # prompt <var_name> <question> <default>
  local __var="$1" __question="$2" __default="$3" __answer
  if [[ -n "${!__var:-}" ]]; then
    return 0   # already set via env var
  fi
  if [[ -t 0 ]]; then
    read -r -p "${__question} [${__default}]: " __answer
  else
    echo -n "${__question} [${__default}]: " > /dev/tty
    read -r __answer < /dev/tty
  fi
  printf -v "$__var" '%s' "${__answer:-$__default}"
}

# ---------- detect sshd systemd unit name ----------
SSHD_UNIT_DETECTED=""
for candidate in ssh sshd; do
  if systemctl list-unit-files "${candidate}.service" --no-legend 2>/dev/null | grep -q "${candidate}.service"; then
    SSHD_UNIT_DETECTED="$candidate"
    break
  fi
done
SSHD_UNIT="${SSHD_UNIT:-$SSHD_UNIT_DETECTED}"
if [[ -z "$SSHD_UNIT" ]]; then
  prompt SSHD_UNIT "Could not auto-detect sshd unit. Enter it (e.g. sshd)" "ssh"
fi
echo "==> Using SSH service unit: ${SSHD_UNIT}"

# ---------- collect settings ----------
if [[ -z "${WEBHOOK_URL:-}" ]]; then
  prompt WEBHOOK_URL "Enter your Discord webhook URL" ""
fi
if [[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" != https://discord.com/api/webhooks/* ]]; then
  echo "That doesn't look like a valid Discord webhook URL (expected https://discord.com/api/webhooks/...)." >&2
  exit 1
fi

prompt DO_GEOIP        "Include GeoIP lookups in notifications? (true/false)" "true"
prompt AUTO_BLOCK      "Auto-block IPs after repeated failed logins? (true/false)" "true"
prompt FAIL_THRESHOLD  "Failed attempts before auto-block" "5"
prompt FAIL_WINDOW     "Time window for the above, in seconds" "600"

# ---------- write shared config ----------
echo "==> Writing /etc/ssh-guard/config.conf"
mkdir -p /etc/ssh-guard
cat > /etc/ssh-guard/config.conf <<EOF
# ssh-guard shared config — used by both ssh-discord-notify.sh and block-ip.sh
WEBHOOK_URL="${WEBHOOK_URL}"
SSHD_UNIT="${SSHD_UNIT}"
DO_GEOIP="${DO_GEOIP}"
AUTO_BLOCK="${AUTO_BLOCK}"
FAIL_THRESHOLD=${FAIL_THRESHOLD}
FAIL_WINDOW=${FAIL_WINDOW}
EOF
chmod 600 /etc/ssh-guard/config.conf
chown root:root /etc/ssh-guard/config.conf

# ---------- install ssh-discord-notify.sh ----------
echo "==> Installing /usr/local/bin/ssh-discord-notify.sh"
cat > /usr/local/bin/ssh-discord-notify.sh <<'NOTIFY_SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/ssh-guard/config.conf"
STATE_DIR="/var/lib/ssh-guard"
FAIL_LOG="${STATE_DIR}/fail_attempts.log"
BLOCK_SCRIPT="/usr/local/bin/block-ip.sh"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "Config file $CONFIG_FILE not found." >&2
  exit 1
fi

: "${WEBHOOK_URL:?WEBHOOK_URL not set in $CONFIG_FILE}"
: "${SSHD_UNIT:=ssh}"
: "${DO_GEOIP:=true}"
: "${AUTO_BLOCK:=true}"
: "${FAIL_THRESHOLD:=5}"
: "${FAIL_WINDOW:=600}"

HOST_LABEL="$(hostname)"
mkdir -p "$STATE_DIR"
touch "$FAIL_LOG"

geoip_lookup() {
  local ip="$1"
  if [[ "$DO_GEOIP" == "true" ]]; then
    curl -s --max-time 3 "http://ip-api.com/json/${ip}?fields=country,regionName,city" \
      | grep -oP '(?<="city":")[^"]*|(?<="regionName":")[^"]*|(?<="country":")[^"]*' \
      | paste -sd, -
  fi
}

send_discord() {
  local title="$1" color="$2" user="$3" ip="$4" extra="${5:-}"
  local loc
  loc="$(geoip_lookup "$ip" || true)"
  [[ -z "$loc" ]] && loc="unknown"

  local fields
  fields=$(cat <<EOF
      {"name": "Host", "value": "$HOST_LABEL", "inline": true},
      {"name": "User", "value": "$user", "inline": true},
      {"name": "Source IP", "value": "$ip", "inline": true},
      {"name": "Location", "value": "$loc", "inline": false}
EOF
)
  if [[ -n "$extra" ]]; then
    fields="${fields},
      {\"name\": \"Detail\", \"value\": \"${extra}\", \"inline\": false}"
  fi

  curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d @- >/dev/null <<EOF
{
  "embeds": [{
    "title": "$title",
    "color": $color,
    "fields": [
$fields
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
}

record_failure_and_count() {
  local ip="$1"
  local now
  now="$(date +%s)"
  echo "${ip}|${now}" >> "$FAIL_LOG"

  local cutoff=$(( now - FAIL_WINDOW ))
  local tmp
  tmp="$(mktemp)"
  awk -F'|' -v cutoff="$cutoff" '$2 >= cutoff' "$FAIL_LOG" > "$tmp" && mv "$tmp" "$FAIL_LOG"

  grep -c "^${ip}|" "$FAIL_LOG" || true
}

maybe_auto_block() {
  local ip="$1" count="$2"

  [[ "$AUTO_BLOCK" != "true" ]] && return 0
  (( count < FAIL_THRESHOLD )) && return 0

  if [[ ! -x "$BLOCK_SCRIPT" ]]; then
    echo "AUTO_BLOCK is enabled but $BLOCK_SCRIPT is missing or not executable." >&2
    return 0
  fi

  "$BLOCK_SCRIPT" add "$ip" "auto-blocked: ${count} failed SSH attempts in ${FAIL_WINDOW}s" || true
}

echo "ssh-discord-notify: watching unit '$SSHD_UNIT'..."

journalctl -fu "$SSHD_UNIT" -o cat --since "now" | while IFS= read -r line; do
  if [[ "$line" =~ Accepted\ (password|publickey|keyboard-interactive)\ for\ ([^[:space:]]+)\ from\ ([^[:space:]]+)\ port ]]; then
    user="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    send_discord "✅ SSH Login Succeeded" 3066993 "$user" "$ip"

  elif [[ "$line" =~ Failed\ password\ for\ (invalid\ user\ )?([^[:space:]]+)\ from\ ([^[:space:]]+)\ port ]]; then
    user="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    count="$(record_failure_and_count "$ip")"
    send_discord "❌ SSH Login Failed" 15158332 "$user" "$ip" "Attempt ${count}/${FAIL_THRESHOLD} in ${FAIL_WINDOW}s window"
    maybe_auto_block "$ip" "$count"

  elif [[ "$line" =~ Connection\ closed\ by\ authenticating\ user\ ([^[:space:]]+)\ ([^[:space:]]+)\ port.*\[preauth\] ]]; then
    user="${BASH_REMATCH[1]}"
    ip="${BASH_REMATCH[2]}"
    send_discord "⚠️ SSH Connection Closed (preauth)" 15105570 "$user" "$ip"
  fi
done
NOTIFY_SCRIPT_EOF
chmod 700 /usr/local/bin/ssh-discord-notify.sh
chown root:root /usr/local/bin/ssh-discord-notify.sh

# ---------- install block-ip.sh ----------
echo "==> Installing /usr/local/bin/block-ip.sh"
cat > /usr/local/bin/block-ip.sh <<'BLOCK_SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/ssh-guard/config.conf"
RECORD_FILE="/etc/ssh-guard/blocked_ips.list"
NFT_TABLE="inet"
NFT_TABLE_NAME="filter"
NFT_SET_NAME="blocked_ips"
IPTABLES_CHAIN="INPUT"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root (try: sudo)" >&2
  exit 1
fi

WEBHOOK_URL=""
DO_GEOIP="true"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

mkdir -p "$(dirname "$RECORD_FILE")"
touch "$RECORD_FILE"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") add <ip> ["reason"]
  $(basename "$0") remove <ip>
  $(basename "$0") list
  $(basename "$0") status <ip>
USAGE
  exit 1
}

is_valid_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    local -a octets=($ip)
    for o in "${octets[@]}"; do
      (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
  fi
  if [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
    return 0
  fi
  return 1
}

geoip_lookup() {
  local ip="$1"
  if [[ "$DO_GEOIP" == "true" ]]; then
    curl -s --max-time 3 "http://ip-api.com/json/${ip}?fields=country,regionName,city" \
      | grep -oP '(?<="city":")[^"]*|(?<="regionName":")[^"]*|(?<="country":")[^"]*' \
      | paste -sd, -
  fi
}

notify_discord() {
  local action="$1" ip="$2" reason="$3"
  [[ -z "${WEBHOOK_URL:-}" ]] && return 0

  local title color loc
  loc="$(geoip_lookup "$ip" || true)"
  [[ -z "$loc" ]] && loc="unknown"

  if [[ "$action" == "block" ]]; then
    title="🚫 IP Blocked"
    color=15158332
  else
    title="✅ IP Unblocked"
    color=3066993
  fi

  curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d @- >/dev/null <<EOF
{
  "embeds": [{
    "title": "$title",
    "color": $color,
    "fields": [
      {"name": "Host", "value": "$(hostname)", "inline": true},
      {"name": "IP", "value": "$ip", "inline": true},
      {"name": "Location", "value": "$loc", "inline": true},
      {"name": "Reason", "value": "$reason", "inline": false}
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
}

detect_backend() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
    echo "ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld"
  elif command -v nft >/dev/null 2>&1; then
    echo "nftables"
  elif command -v iptables >/dev/null 2>&1; then
    echo "iptables"
  else
    echo "none"
  fi
}

BACKEND="$(detect_backend)"
if [[ "$BACKEND" == "none" ]]; then
  echo "No supported firewall tool found (ufw, firewalld, nft, or iptables)." >&2
  exit 1
fi

ensure_nft_setup() {
  nft list table "${NFT_TABLE} ${NFT_TABLE_NAME}" >/dev/null 2>&1 || \
    nft add table "${NFT_TABLE} ${NFT_TABLE_NAME}"
  nft list chain "${NFT_TABLE} ${NFT_TABLE_NAME} input" >/dev/null 2>&1 || \
    nft add chain "${NFT_TABLE} ${NFT_TABLE_NAME}" input '{ type filter hook input priority 0 ; }'
  nft list set "${NFT_TABLE} ${NFT_TABLE_NAME} ${NFT_SET_NAME}" >/dev/null 2>&1 || \
    nft add set "${NFT_TABLE} ${NFT_TABLE_NAME}" "${NFT_SET_NAME}" '{ type ipv4_addr ; flags interval ; }'
  nft list chain "${NFT_TABLE} ${NFT_TABLE_NAME} input" | grep -q "@${NFT_SET_NAME}" || \
    nft insert rule "${NFT_TABLE} ${NFT_TABLE_NAME}" input ip saddr "@${NFT_SET_NAME}" drop
}

backend_add() {
  local ip="$1"
  case "$BACKEND" in
    ufw)
      ufw deny from "$ip" to any >/dev/null
      ;;
    firewalld)
      firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ip}' drop" >/dev/null
      firewall-cmd --reload >/dev/null
      ;;
    nftables)
      ensure_nft_setup
      nft add element "${NFT_TABLE} ${NFT_TABLE_NAME}" "${NFT_SET_NAME}" "{ ${ip} }"
      ;;
    iptables)
      if ! iptables -C "$IPTABLES_CHAIN" -s "$ip" -j DROP 2>/dev/null; then
        iptables -I "$IPTABLES_CHAIN" -s "$ip" -j DROP
      fi
      ;;
  esac
}

backend_remove() {
  local ip="$1"
  case "$BACKEND" in
    ufw)
      ufw delete deny from "$ip" to any >/dev/null 2>&1 || true
      ;;
    firewalld)
      firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${ip}' drop" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null
      ;;
    nftables)
      nft delete element "${NFT_TABLE} ${NFT_TABLE_NAME}" "${NFT_SET_NAME}" "{ ${ip} }" 2>/dev/null || true
      ;;
    iptables)
      while iptables -C "$IPTABLES_CHAIN" -s "$ip" -j DROP 2>/dev/null; do
        iptables -D "$IPTABLES_CHAIN" -s "$ip" -j DROP
      done
      ;;
  esac
}

cmd_add() {
  local ip="$1"; shift || true
  local reason="${*:-no reason given}"

  is_valid_ip "$ip" || { echo "Invalid IP address: $ip" >&2; exit 1; }

  if grep -q "^${ip}|" "$RECORD_FILE" 2>/dev/null; then
    echo "IP $ip is already blocked."
    exit 0
  fi

  backend_add "$ip"
  echo "${ip}|$(date -u +%Y-%m-%dT%H:%M:%SZ)|${reason}" >> "$RECORD_FILE"
  echo "Blocked $ip (backend: $BACKEND). Reason: $reason"
  notify_discord "block" "$ip" "$reason"
}

cmd_remove() {
  local ip="$1"
  is_valid_ip "$ip" || { echo "Invalid IP address: $ip" >&2; exit 1; }

  backend_remove "$ip"
  sed -i "\#^${ip}|#d" "$RECORD_FILE"
  echo "Unblocked $ip (backend: $BACKEND)."
  notify_discord "unblock" "$ip" "manually unblocked"
}

cmd_list() {
  if [[ ! -s "$RECORD_FILE" ]]; then
    echo "No IPs currently blocked."
    return
  fi
  printf "%-16s %-22s %s\n" "IP" "Blocked At (UTC)" "Reason"
  printf -- "-%.0s" {1..70}; echo
  while IFS='|' read -r ip ts reason; do
    printf "%-16s %-22s %s\n" "$ip" "$ts" "$reason"
  done < "$RECORD_FILE"
}

cmd_status() {
  local ip="$1"
  if grep -q "^${ip}|" "$RECORD_FILE" 2>/dev/null; then
    echo "$ip is BLOCKED."
    grep "^${ip}|" "$RECORD_FILE"
  else
    echo "$ip is not blocked (per record file)."
  fi
}

[[ $# -lt 1 ]] && usage

case "$1" in
  add)
    [[ $# -lt 2 ]] && usage
    shift
    cmd_add "$@"
    ;;
  remove|rm|unblock)
    [[ $# -ne 2 ]] && usage
    cmd_remove "$2"
    ;;
  list|ls)
    cmd_list
    ;;
  status)
    [[ $# -ne 2 ]] && usage
    cmd_status "$2"
    ;;
  *)
    usage
    ;;
esac
BLOCK_SCRIPT_EOF
chmod 700 /usr/local/bin/block-ip.sh
chown root:root /usr/local/bin/block-ip.sh

# ---------- systemd unit ----------
echo "==> Installing /etc/systemd/system/ssh-discord-notify.service"
cat > /etc/systemd/system/ssh-discord-notify.service <<UNIT_EOF
[Unit]
Description=SSH login attempt notifier + auto-block (Discord)
After=network-online.target ${SSHD_UNIT}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssh-discord-notify.sh
Restart=always
RestartSec=5
User=root
Nice=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

echo "==> Reloading systemd and starting the service"
systemctl daemon-reload
systemctl enable --now ssh-discord-notify.service

sleep 1
if systemctl is-active --quiet ssh-discord-notify.service; then
  echo "==> ssh-discord-notify is running."
else
  echo "==> Service failed to start. Check: journalctl -u ssh-discord-notify -n 50" >&2
  exit 1
fi

echo "==> Sending a test message to Discord..."
curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d '{
  "embeds": [{
    "title": "🔧 SSH Guard Installed",
    "color": 3447003,
    "description": "This host will now report SSH login attempts, and auto-block IPs after repeated failures, here.",
    "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
  }]
}' >/dev/null || echo "Warning: test message failed to send. Double-check the webhook URL." >&2

cat <<DONE

Installed successfully.

  Config:      sudo nano /etc/ssh-guard/config.conf   (then: sudo systemctl restart ssh-discord-notify)
  Logs:        sudo journalctl -u ssh-discord-notify -f
  Restart:     sudo systemctl restart ssh-discord-notify
  Blocked IPs: sudo block-ip.sh list
  Manual block:   sudo block-ip.sh add <ip> "reason"
  Manual unblock: sudo block-ip.sh remove <ip>

  Uninstall:
    sudo systemctl disable --now ssh-discord-notify
    sudo rm -f /usr/local/bin/ssh-discord-notify.sh /usr/local/bin/block-ip.sh \\
      /etc/systemd/system/ssh-discord-notify.service
    sudo rm -rf /etc/ssh-guard /var/lib/ssh-guard
    sudo systemctl daemon-reload

DONE
