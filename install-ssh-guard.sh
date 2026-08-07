#!/usr/bin/env bash
#
# install-ssh-guard.sh — SSH Discord Notifier + Auto-Block + Reports installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pjortiz/ssh-guard/refs/heads/main/install-ssh-guard.sh | sudo bash
#
#   Non-interactive:
#   curl -fsSL .../install-ssh-guard.sh | sudo \
#     WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy" \
#     AUTO_BLOCK=true FAIL_THRESHOLD=5 FAIL_WINDOW=600 \
#     NOTIFY_FAILED_ATTEMPTS=true NOTIFY_ON_BLOCK=true \
#     MENTION_DEFAULT=none REPORT_ENABLED=false REPORT_CRON="0 8 * * *" \
#     bash
#
# Installs:
#   /etc/ssh-guard/config.conf                 (shared settings, webhook URL, mentions)
#   /usr/local/bin/ssh-discord-notify.sh       (watches journal, notifies, auto-blocks)
#   /usr/local/bin/block-ip.sh                 (manual/automatic IP block/unblock)
#   /usr/local/bin/ssh-guard-report.sh         (periodic Discord summary report)
#   /etc/systemd/system/ssh-discord-notify.service
#   /etc/cron.d/ssh-guard-report               (cron schedule for the report; self-gates on REPORT_ENABLED)
#
set -euo pipefail

# ---------- must be root ----------
if [[ "${EUID}" -ne 0 ]]; then
  echo "This installer must be run as root (try: sudo bash install-ssh-guard.sh)" >&2
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

if ! command -v crontab >/dev/null 2>&1 \
   && ! systemctl list-unit-files 2>/dev/null | grep -qiE '^(cron|crond)\.service'; then
  echo "No cron daemon detected (cron/crond). Periodic reports will only run if you invoke" >&2
  echo "/usr/local/bin/ssh-guard-report.sh manually, or install a cron package (e.g. apt install cron)." >&2
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

# ---------- load existing config (if any) as defaults for a clean rerun ----------
EXISTING_CONFIG="/etc/ssh-guard/config.conf"
_EXISTING_WEBHOOK_URL="" _EXISTING_SSHD_UNIT="" _EXISTING_DO_GEOIP=""
_EXISTING_AUTO_BLOCK="" _EXISTING_FAIL_THRESHOLD="" _EXISTING_FAIL_WINDOW=""
_EXISTING_NOTIFY_FAILED_ATTEMPTS="" _EXISTING_NOTIFY_ON_BLOCK=""
_EXISTING_MENTION_ON_FAILURE="" _EXISTING_REPORT_ENABLED="" _EXISTING_REPORT_CRON=""
if [[ -f "$EXISTING_CONFIG" ]]; then
  echo "==> Existing config found at $EXISTING_CONFIG — its values will be offered as defaults."
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Z_]+=' "$EXISTING_CONFIG" | sed 's/^/_EXISTING_/')
fi

# ---------- detect sshd systemd unit name ----------
SSHD_UNIT_DETECTED=""
for candidate in ssh sshd; do
  if systemctl list-unit-files "${candidate}.service" --no-legend 2>/dev/null | grep -q "${candidate}.service"; then
    SSHD_UNIT_DETECTED="$candidate"
    break
  fi
done
SSHD_UNIT="${SSHD_UNIT:-${_EXISTING_SSHD_UNIT:-$SSHD_UNIT_DETECTED}}"
if [[ -z "$SSHD_UNIT" ]]; then
  prompt SSHD_UNIT "Could not auto-detect sshd unit. Enter it (e.g. sshd)" "ssh"
fi
echo "==> Using SSH service unit: ${SSHD_UNIT}"

# ---------- collect settings (existing config values are offered as defaults) ----------
if [[ -z "${WEBHOOK_URL:-}" ]]; then
  prompt WEBHOOK_URL "Enter your Discord webhook URL" "${_EXISTING_WEBHOOK_URL:-}"
fi
if [[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" != https://discord.com/api/webhooks/* ]]; then
  echo "That doesn't look like a valid Discord webhook URL (expected https://discord.com/api/webhooks/...)." >&2
  exit 1
fi

prompt DO_GEOIP        "Include GeoIP lookups in notifications? (true/false)" "${_EXISTING_DO_GEOIP:-true}"
prompt AUTO_BLOCK      "Auto-block IPs after repeated failed logins? (true/false)" "${_EXISTING_AUTO_BLOCK:-true}"
prompt FAIL_THRESHOLD  "Failed attempts before auto-block" "${_EXISTING_FAIL_THRESHOLD:-5}"
prompt FAIL_WINDOW     "Time window for the above, in seconds" "${_EXISTING_FAIL_WINDOW:-600}"
prompt NOTIFY_FAILED_ATTEMPTS "Send a Discord message for EVERY failed/preauth attempt? (false = stay quiet until an IP is actually blocked; repeat offenders past the threshold above always notify regardless)" "${_EXISTING_NOTIFY_FAILED_ATTEMPTS:-true}"
prompt NOTIFY_ON_BLOCK "Send a Discord message when an IP gets blocked? (false = block silently)" "${_EXISTING_NOTIFY_ON_BLOCK:-true}"
prompt MENTION_DEFAULT "Default @mention for ALL notification types — none / everyone / role:<id> / user:<id> (you can fine-tune each type individually afterward by editing config.conf; this will overwrite any such per-type customization)" "${_EXISTING_MENTION_ON_FAILURE:-none}"
prompt REPORT_ENABLED  "Enable periodic summary reports (failed/invalid/blocked counts + blocked IP list) via cron? (true/false)" "${_EXISTING_REPORT_ENABLED:-false}"
prompt REPORT_CRON     "Cron schedule for the report (standard 5-field cron syntax)" "${_EXISTING_REPORT_CRON:-0 8 * * *}"


# ---------- write shared config ----------
echo "==> Writing /etc/ssh-guard/config.conf"
mkdir -p /etc/ssh-guard
cat > /etc/ssh-guard/config.conf <<EOF
# ssh-guard shared config — used by ssh-discord-notify.sh, block-ip.sh, and ssh-guard-report.sh
WEBHOOK_URL="${WEBHOOK_URL}"
SSHD_UNIT="${SSHD_UNIT}"
DO_GEOIP="${DO_GEOIP}"
AUTO_BLOCK="${AUTO_BLOCK}"
FAIL_THRESHOLD=${FAIL_THRESHOLD}
FAIL_WINDOW=${FAIL_WINDOW}
NOTIFY_FAILED_ATTEMPTS="${NOTIFY_FAILED_ATTEMPTS}"

# Notification toggles
NOTIFY_ON_BLOCK="${NOTIFY_ON_BLOCK}"
NOTIFY_ON_UNBLOCK="true"

# @mentions per notification type: none / everyone / role:<id> / user:<id>
MENTION_ON_FAILURE="${MENTION_DEFAULT}"
MENTION_ON_SUCCESS="${MENTION_DEFAULT}"
MENTION_ON_BLOCK="${MENTION_DEFAULT}"
MENTION_ON_UNBLOCK="${MENTION_DEFAULT}"
MENTION_ON_REPORT="${MENTION_DEFAULT}"

# Periodic summary report (see /etc/cron.d/ssh-guard-report)
REPORT_ENABLED="${REPORT_ENABLED}"
REPORT_CRON="${REPORT_CRON}"
EOF
chmod 600 /etc/ssh-guard/config.conf
chown root:root /etc/ssh-guard/config.conf

# ---------- install ssh-discord-notify.sh ----------
echo "==> Installing /usr/local/bin/ssh-discord-notify.sh"
cat > /usr/local/bin/ssh-discord-notify.sh <<'NOTIFY_SCRIPT_EOF'
#!/usr/bin/env bash
#
# ssh-discord-notify.sh
# Tails the SSH journal, posts Discord embeds on login success/failure,
# and — if enabled — auto-blocks an IP after too many failures in a
# time window by calling block-ip.sh. Also feeds persistent counters
# used by ssh-guard-report.sh for periodic summaries.
#
set -euo pipefail

CONFIG_FILE="/etc/ssh-guard/config.conf"
STATE_DIR="/var/lib/ssh-guard"
FAIL_LOG="${STATE_DIR}/fail_attempts.log"
LIFETIME_FILE="${STATE_DIR}/lifetime_fail_counts.tsv"
BLOCK_SCRIPT="/usr/local/bin/block-ip.sh"

COUNTER_FAILED_PW="${STATE_DIR}/counter_failed_password.count"
COUNTER_INVALID_USER="${STATE_DIR}/counter_invalid_user.count"
COUNTER_PREAUTH="${STATE_DIR}/counter_preauth_closed.count"
COUNTER_PROBE="${STATE_DIR}/counter_probe.count"

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
: "${NOTIFY_FAILED_ATTEMPTS:=true}"
: "${MENTION_ON_FAILURE:=none}"
: "${MENTION_ON_SUCCESS:=none}"

HOST_LABEL="$(hostname)"
mkdir -p "$STATE_DIR"
touch "$FAIL_LOG" "$LIFETIME_FILE" \
  "$COUNTER_FAILED_PW" "$COUNTER_INVALID_USER" "$COUNTER_PREAUTH" "$COUNTER_PROBE"

# ---------- helpers ----------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

geoip_lookup() {
  local ip="$1"
  if [[ "$DO_GEOIP" == "true" ]]; then
    curl -s --max-time 3 "http://ip-api.com/json/${ip}?fields=country,regionName,city" \
      | grep -oP '(?<="city":")[^"]*|(?<="regionName":")[^"]*|(?<="country":")[^"]*' \
      | paste -sd, -
  fi
}

# Translates a mention spec (none / everyone / role:<id> / user:<id>) into
# the Discord "content" mention string + the matching allowed_mentions JSON.
compute_mention() {
  local spec="$1"
  MENTION_CONTENT=""
  MENTION_ALLOWED_JSON='{"parse": []}'
  case "$spec" in
    ""|none|NONE) ;;
    everyone|EVERYONE)
      MENTION_CONTENT="@everyone"
      MENTION_ALLOWED_JSON='{"parse": ["everyone"]}'
      ;;
    role:*)
      local rid="${spec#role:}"
      MENTION_CONTENT="<@&${rid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"roles\": [\"${rid}\"]}"
      ;;
    user:*)
      local uid="${spec#user:}"
      MENTION_CONTENT="<@${uid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"users\": [\"${uid}\"]}"
      ;;
  esac
}

increment_counter() {
  local file="$1"
  local val
  val="$(cat "$file" 2>/dev/null)"
  [[ -z "$val" ]] && val=0
  val=$(( val + 1 ))
  echo "$val" > "$file"
}

send_discord() {
  local title="$1" color="$2" user="$3" ip="$4" extra="${5:-}" mention_spec="${6:-none}"
  local loc
  loc="$(geoip_lookup "$ip" || true)"
  [[ -z "$loc" ]] && loc="unknown"

  local fields
  fields=$(cat <<EOF
      {"name": "Host", "value": "$(json_escape "$HOST_LABEL")", "inline": true},
      {"name": "User", "value": "$(json_escape "$user")", "inline": true},
      {"name": "Source IP", "value": "$(json_escape "$ip")", "inline": true},
      {"name": "Location", "value": "$(json_escape "$loc")", "inline": false}
EOF
)
  if [[ -n "$extra" ]]; then
    fields="${fields},
      {\"name\": \"Detail\", \"value\": \"$(json_escape "$extra")\", \"inline\": false}"
  fi

  compute_mention "$mention_spec"

  curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d @- >/dev/null <<EOF
{
  "content": "${MENTION_CONTENT}",
  "allowed_mentions": ${MENTION_ALLOWED_JSON},
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

# Records a failure for $ip, prunes entries older than FAIL_WINDOW,
# and returns the current count of failures within the window.
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

# Increments (or creates) the all-time failure count for $ip in
# LIFETIME_FILE (tab-separated "ip<TAB>count", never pruned) and
# echoes the new total.
increment_lifetime_count() {
  local ip="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v ip="$ip" -v OFS='\t' '
    $1 == ip { $2 = $2 + 1; found=1 }
    { print }
    END { if (!found) print ip, 1 }
  ' "$LIFETIME_FILE" > "$tmp"
  mv "$tmp" "$LIFETIME_FILE"
  awk -F'\t' -v ip="$ip" '$1 == ip { print $2 }' "$LIFETIME_FILE"
}

# Reads (without incrementing) the current lifetime failure count for an IP.
get_lifetime_count() {
  local ip="$1"
  local n
  n="$(awk -F'\t' -v ip="$ip" '$1 == ip { print $2 }' "$LIFETIME_FILE" 2>/dev/null)"
  echo "${n:-0}"
}

# Decides whether a failed-attempt notification should be sent: yes if
# NOTIFY_FAILED_ATTEMPTS is true, OR if this IP is a repeat offender
# whose lifetime failure count already exceeds FAIL_THRESHOLD — so
# persistent attackers still get surfaced even when per-attempt
# notifications are otherwise muted.
should_notify_failure() {
  local lifetime="$1"
  if [[ "$NOTIFY_FAILED_ATTEMPTS" == "true" ]]; then
    return 0
  fi
  if (( lifetime > FAIL_THRESHOLD )); then
    return 0
  fi
  return 1
}

maybe_auto_block() {
  local ip="$1" count="$2"

  [[ "$AUTO_BLOCK" != "true" ]] && return 0
  (( count < FAIL_THRESHOLD )) && return 0

  if [[ ! -x "$BLOCK_SCRIPT" ]]; then
    echo "AUTO_BLOCK is enabled but $BLOCK_SCRIPT is missing or not executable." >&2
    return 0
  fi

  # block-ip.sh add is idempotent, and it sends its own Discord
  # notification (via the shared config) when it actually blocks.
  "$BLOCK_SCRIPT" add "$ip" "auto-blocked: ${count} failed SSH attempts in ${FAIL_WINDOW}s" || true
}

echo "ssh-discord-notify: watching unit '$SSHD_UNIT'..."

journalctl -fu "$SSHD_UNIT" -o cat --since "now" | while IFS= read -r line; do
  if [[ "$line" =~ Accepted\ (password|publickey|keyboard-interactive)\ for\ ([^[:space:]]+)\ from\ ([^[:space:]]+)\ port ]]; then
    user="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    # Deliberately uses a warning icon/color, not a green checkmark — a
    # successful login is exactly the event you want to notice immediately,
    # since it could be you... or it could be an intrusion.
    send_discord "⚠️ SSH Login Succeeded" 16753920 "$user" "$ip" "" "$MENTION_ON_SUCCESS"

  elif [[ "$line" =~ Failed\ password\ for\ (invalid\ user\ )?([^[:space:]]+)\ from\ ([^[:space:]]+)\ port ]]; then
    user="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    count="$(record_failure_and_count "$ip")"
    lifetime="$(increment_lifetime_count "$ip")"
    increment_counter "$COUNTER_FAILED_PW"
    if should_notify_failure "$lifetime"; then
      send_discord "❌ SSH Login Failed" 15158332 "$user" "$ip" "Attempt ${count}/${FAIL_THRESHOLD} in ${FAIL_WINDOW}s window • Lifetime failed attempts from this IP: ${lifetime}" "$MENTION_ON_FAILURE"
    fi
    maybe_auto_block "$ip" "$count"

  elif [[ "$line" =~ Invalid\ user\ ([^[:space:]]*)\ from\ ([^[:space:]]+)\ port ]]; then
    raw_user="${BASH_REMATCH[1]}"
    user="${raw_user:-<blank>}"
    ip="${BASH_REMATCH[2]}"
    count="$(record_failure_and_count "$ip")"
    lifetime="$(increment_lifetime_count "$ip")"
    increment_counter "$COUNTER_INVALID_USER"
    if should_notify_failure "$lifetime"; then
      send_discord "❌ SSH Login Failed" 15158332 "$user" "$ip" "Invalid username, rejected before password prompt • Attempt ${count}/${FAIL_THRESHOLD} in ${FAIL_WINDOW}s window • Lifetime failed attempts from this IP: ${lifetime}" "$MENTION_ON_FAILURE"
    fi
    maybe_auto_block "$ip" "$count"

  elif [[ "$line" =~ (Connection\ closed\ by|Disconnected\ from)\ authenticating\ user\ ([^[:space:]]+)\ ([^[:space:]]+)\ port.*\[preauth\] ]]; then
    user="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    lifetime="$(get_lifetime_count "$ip")"
    increment_counter "$COUNTER_PREAUTH"
    if should_notify_failure "$lifetime"; then
      send_discord "⚠️ SSH Connection Closed (preauth)" 15105570 "$user" "$ip" "" "$MENTION_ON_FAILURE"
    fi

  elif [[ "$line" =~ ^Connection\ closed\ by\ ([^[:space:]]+)\ port\ [0-9]+\ \[preauth\]$ ]]; then
    # Bare "Connection closed by <ip> port <port> [preauth]" with no
    # username at all — a plain port scan / banner grab, no auth
    # attempted. Counted for the periodic report, but never notified
    # individually — every scanner on the internet triggers this.
    increment_counter "$COUNTER_PROBE"
  fi
done
NOTIFY_SCRIPT_EOF
chmod 700 /usr/local/bin/ssh-discord-notify.sh
chown root:root /usr/local/bin/ssh-discord-notify.sh

# ---------- install block-ip.sh ----------
echo "==> Installing /usr/local/bin/block-ip.sh"
cat > /usr/local/bin/block-ip.sh <<'BLOCK_SCRIPT_EOF'
#!/usr/bin/env bash
#
# block-ip.sh — add/remove/list blocked IPs
#
# Auto-detects the active firewall backend (ufw, firewalld, nftables,
# or plain iptables) and uses it. Keeps its own record file so `list`
# and `status` work consistently no matter which backend is active.
#
# If /etc/ssh-guard/config.conf exists and has WEBHOOK_URL set, this
# script will also post a Discord notification whenever it blocks or
# unblocks an IP (works standalone too — Discord notification is
# simply skipped if the config/webhook isn't present).
#
# Usage:
#   sudo block-ip.sh add <ip> ["reason"]
#   sudo block-ip.sh remove <ip>
#   sudo block-ip.sh list
#   sudo block-ip.sh status <ip>
#   sudo block-ip.sh sync
#   sudo block-ip.sh config
#   sudo block-ip.sh rules
#
set -euo pipefail

CONFIG_FILE="/etc/ssh-guard/config.conf"
RECORD_FILE="/etc/ssh-guard/blocked_ips.list"
LIFETIME_FILE="/var/lib/ssh-guard/lifetime_fail_counts.tsv"
COUNTER_BLOCKS_TOTAL="/var/lib/ssh-guard/counter_blocks_total.count"
NFT_TABLE="inet"
NFT_TABLE_NAME="filter"
NFT_SET_NAME="blocked_ips"
IPTABLES_CHAIN="INPUT"

# ---------- must be root ----------
if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root (try: sudo)" >&2
  exit 1
fi

# ---------- optional shared config (webhook, mentions, etc.) ----------
WEBHOOK_URL=""
DO_GEOIP="true"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/etc/ssh-guard/config.conf
  source "$CONFIG_FILE"
fi
: "${NOTIFY_ON_BLOCK:=true}"
: "${NOTIFY_ON_UNBLOCK:=true}"
: "${MENTION_ON_BLOCK:=none}"
: "${MENTION_ON_UNBLOCK:=none}"

mkdir -p "$(dirname "$RECORD_FILE")" "$(dirname "$COUNTER_BLOCKS_TOTAL")"
touch "$RECORD_FILE" "$COUNTER_BLOCKS_TOTAL"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") add <ip> ["reason"]
  $(basename "$0") remove <ip>
  $(basename "$0") list
  $(basename "$0") status <ip>
  $(basename "$0") sync
  $(basename "$0") config
  $(basename "$0") rules
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

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

geoip_lookup() {
  local ip="$1"
  if [[ "$DO_GEOIP" == "true" ]]; then
    curl -s --max-time 3 "http://ip-api.com/json/${ip}?fields=country,regionName,city" \
      | grep -oP '(?<="city":")[^"]*|(?<="regionName":")[^"]*|(?<="country":")[^"]*' \
      | paste -sd, -
  fi
}

compute_mention() {
  local spec="$1"
  MENTION_CONTENT=""
  MENTION_ALLOWED_JSON='{"parse": []}'
  case "$spec" in
    ""|none|NONE) ;;
    everyone|EVERYONE)
      MENTION_CONTENT="@everyone"
      MENTION_ALLOWED_JSON='{"parse": ["everyone"]}'
      ;;
    role:*)
      local rid="${spec#role:}"
      MENTION_CONTENT="<@&${rid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"roles\": [\"${rid}\"]}"
      ;;
    user:*)
      local uid="${spec#user:}"
      MENTION_CONTENT="<@${uid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"users\": [\"${uid}\"]}"
      ;;
  esac
}

notify_discord() {
  local action="$1" ip="$2" reason="$3"
  [[ -z "${WEBHOOK_URL:-}" ]] && return 0

  local enabled mention_spec
  if [[ "$action" == "block" ]]; then
    enabled="$NOTIFY_ON_BLOCK"
    mention_spec="$MENTION_ON_BLOCK"
  else
    enabled="$NOTIFY_ON_UNBLOCK"
    mention_spec="$MENTION_ON_UNBLOCK"
  fi
  [[ "$enabled" != "true" ]] && return 0

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

  compute_mention "$mention_spec"

  curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d @- >/dev/null <<EOF
{
  "content": "${MENTION_CONTENT}",
  "allowed_mentions": ${MENTION_ALLOWED_JSON},
  "embeds": [{
    "title": "$title",
    "color": $color,
    "fields": [
      {"name": "Host", "value": "$(json_escape "$(hostname)")", "inline": true},
      {"name": "IP", "value": "$(json_escape "$ip")", "inline": true},
      {"name": "Location", "value": "$(json_escape "$loc")", "inline": true},
      {"name": "Reason", "value": "$(json_escape "$reason")", "inline": false}
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
}

# ---------- detect backend ----------
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

  local val
  val="$(cat "$COUNTER_BLOCKS_TOTAL" 2>/dev/null)"
  [[ -z "$val" ]] && val=0
  echo $(( val + 1 )) > "$COUNTER_BLOCKS_TOTAL"

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

cmd_rules() {
  echo "Firewall backend: $BACKEND"
  echo "--------------------------------------------------------"
  case "$BACKEND" in
    ufw)
      ufw status numbered
      ;;
    firewalld)
      echo "Default zone: $(firewall-cmd --get-default-zone 2>/dev/null || echo unknown)"
      echo
      echo "Rich rules (includes our blocks and any others):"
      firewall-cmd --list-rich-rules 2>/dev/null || echo "(none, or firewalld not running)"
      ;;
    nftables)
      if nft list table "${NFT_TABLE} ${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        nft list table "${NFT_TABLE} ${NFT_TABLE_NAME}"
      else
        echo "(table '${NFT_TABLE} ${NFT_TABLE_NAME}' not created yet — no IPs blocked so far)"
      fi
      ;;
    iptables)
      local out
      out="$(iptables -L "$IPTABLES_CHAIN" -n -v --line-numbers 2>/dev/null)"
      echo "$out" | head -2
      echo "$out" | grep -E '\bDROP\b' || echo "(no DROP rules currently in $IPTABLES_CHAIN)"
      ;;
  esac
}

mask_webhook() {
  local url="$1"
  if [[ -z "$url" ]]; then
    echo "(not set)"
    return
  fi
  local prefix token
  prefix="${url%/*}"
  token="${url##*/}"
  if [[ ${#token} -gt 4 ]]; then
    echo "${prefix}/${token:0:4}**********(hidden)"
  else
    echo "${prefix}/**********(hidden)"
  fi
}

cmd_config() {
  echo "Config file: $CONFIG_FILE"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "(not found — block-ip.sh is running standalone, without Discord notifications)"
  else
    echo "--------------------------------------------------------"
    printf "%-24s %s\n" "WEBHOOK_URL"            "$(mask_webhook "${WEBHOOK_URL:-}")"
    printf "%-24s %s\n" "SSHD_UNIT"              "${SSHD_UNIT:-(unset)}"
    printf "%-24s %s\n" "DO_GEOIP"               "${DO_GEOIP:-(unset)}"
    printf "%-24s %s\n" "AUTO_BLOCK"             "${AUTO_BLOCK:-(unset)}"
    printf "%-24s %s\n" "FAIL_THRESHOLD"         "${FAIL_THRESHOLD:-(unset)}"
    printf "%-24s %s\n" "FAIL_WINDOW"            "${FAIL_WINDOW:-(unset)}s"
    printf "%-24s %s\n" "NOTIFY_FAILED_ATTEMPTS" "${NOTIFY_FAILED_ATTEMPTS:-(unset)}"
    printf "%-24s %s\n" "NOTIFY_ON_BLOCK"        "${NOTIFY_ON_BLOCK:-(unset)}"
    printf "%-24s %s\n" "NOTIFY_ON_UNBLOCK"      "${NOTIFY_ON_UNBLOCK:-(unset)}"
    printf "%-24s %s\n" "MENTION_ON_FAILURE"     "${MENTION_ON_FAILURE:-(unset)}"
    printf "%-24s %s\n" "MENTION_ON_SUCCESS"     "${MENTION_ON_SUCCESS:-(unset)}"
    printf "%-24s %s\n" "MENTION_ON_BLOCK"       "${MENTION_ON_BLOCK:-(unset)}"
    printf "%-24s %s\n" "MENTION_ON_UNBLOCK"     "${MENTION_ON_UNBLOCK:-(unset)}"
    printf "%-24s %s\n" "REPORT_ENABLED"         "${REPORT_ENABLED:-(unset)}"
    printf "%-24s %s\n" "REPORT_CRON"            "${REPORT_CRON:-(unset)}"
    printf "%-24s %s\n" "MENTION_ON_REPORT"      "${MENTION_ON_REPORT:-(unset)}"
  fi

  echo
  echo "Firewall backend: $BACKEND"
  echo "Record file:      $RECORD_FILE"
  local n_blocked
  n_blocked="$(wc -l < "$RECORD_FILE" 2>/dev/null || echo 0)"
  n_blocked="$(echo "$n_blocked" | tr -d '[:space:]')"
  echo "IPs currently blocked (recorded): $n_blocked"
}

cmd_sync() {
  if [[ ! -s "$RECORD_FILE" ]]; then
    echo "No recorded IPs to sync."
    return
  fi

  local count=0
  while IFS='|' read -r ip _ts _reason; do
    [[ -z "$ip" ]] && continue
    backend_add "$ip" || echo "Warning: failed to (re)apply rule for $ip" >&2
    count=$(( count + 1 ))
  done < "$RECORD_FILE"
  echo "Synced $count recorded IP(s) to the $BACKEND firewall."
}

cmd_status() {
  local ip="$1"
  if grep -q "^${ip}|" "$RECORD_FILE" 2>/dev/null; then
    echo "$ip is BLOCKED."
    grep "^${ip}|" "$RECORD_FILE"
  else
    echo "$ip is not blocked (per record file)."
  fi

  if [[ -f "$LIFETIME_FILE" ]]; then
    local lifetime
    lifetime="$(awk -F'\t' -v ip="$ip" '$1 == ip { print $2 }' "$LIFETIME_FILE")"
    if [[ -n "$lifetime" ]]; then
      echo "Lifetime failed SSH attempts from this IP: $lifetime"
    fi
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
  sync)
    cmd_sync
    ;;
  config)
    cmd_config
    ;;
  rules)
    cmd_rules
    ;;
  *)
    usage
    ;;
esac
BLOCK_SCRIPT_EOF
chmod 700 /usr/local/bin/block-ip.sh
chown root:root /usr/local/bin/block-ip.sh

# ---------- install ssh-guard-report.sh ----------
echo "==> Installing /usr/local/bin/ssh-guard-report.sh"
cat > /usr/local/bin/ssh-guard-report.sh <<'REPORT_SCRIPT_EOF'
#!/usr/bin/env bash
#
# ssh-guard-report.sh
# Sends a periodic Discord summary: failed/invalid/preauth/probe counts
# since the last report, how many IPs were newly blocked, and the full
# list of currently blocked IPs with reasons. Meant to be run on a cron
# schedule (see REPORT_CRON in /etc/ssh-guard/config.conf), but can also
# be run manually at any time.
#
# Does nothing (exits 0 silently) unless REPORT_ENABLED=true in config,
# so it's safe to leave the cron job installed even when reports are
# turned off.
#
set -euo pipefail

CONFIG_FILE="/etc/ssh-guard/config.conf"
STATE_DIR="/var/lib/ssh-guard"
RECORD_FILE="/etc/ssh-guard/blocked_ips.list"
BASELINE_FILE="${STATE_DIR}/report_baseline.tsv"

COUNTER_FAILED_PW="${STATE_DIR}/counter_failed_password.count"
COUNTER_INVALID_USER="${STATE_DIR}/counter_invalid_user.count"
COUNTER_PREAUTH="${STATE_DIR}/counter_preauth_closed.count"
COUNTER_PROBE="${STATE_DIR}/counter_probe.count"
COUNTER_BLOCKS_TOTAL="${STATE_DIR}/counter_blocks_total.count"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/etc/ssh-guard/config.conf
  source "$CONFIG_FILE"
else
  echo "Config file $CONFIG_FILE not found." >&2
  exit 1
fi

: "${WEBHOOK_URL:?WEBHOOK_URL not set in $CONFIG_FILE}"
: "${REPORT_ENABLED:=false}"
: "${MENTION_ON_REPORT:=none}"

if [[ "$REPORT_ENABLED" != "true" ]]; then
  exit 0
fi

mkdir -p "$STATE_DIR"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

compute_mention() {
  local spec="$1"
  MENTION_CONTENT=""
  MENTION_ALLOWED_JSON='{"parse": []}'
  case "$spec" in
    ""|none|NONE) ;;
    everyone|EVERYONE)
      MENTION_CONTENT="@everyone"
      MENTION_ALLOWED_JSON='{"parse": ["everyone"]}'
      ;;
    role:*)
      local rid="${spec#role:}"
      MENTION_CONTENT="<@&${rid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"roles\": [\"${rid}\"]}"
      ;;
    user:*)
      local uid="${spec#user:}"
      MENTION_CONTENT="<@${uid}>"
      MENTION_ALLOWED_JSON="{\"parse\": [], \"users\": [\"${uid}\"]}"
      ;;
  esac
}

read_counter() {
  local file="$1"
  local val
  val="$(cat "$file" 2>/dev/null)"
  [[ -z "$val" ]] && val=0
  echo "$val"
}

cur_failed_pw="$(read_counter "$COUNTER_FAILED_PW")"
cur_invalid_user="$(read_counter "$COUNTER_INVALID_USER")"
cur_preauth="$(read_counter "$COUNTER_PREAUTH")"
cur_probe="$(read_counter "$COUNTER_PROBE")"
cur_blocks_total="$(read_counter "$COUNTER_BLOCKS_TOTAL")"

base_failed_pw=0
base_invalid_user=0
base_preauth=0
base_probe=0
base_blocks_total=0
base_time=""
if [[ -f "$BASELINE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$BASELINE_FILE"
fi

delta_failed_pw=$(( cur_failed_pw - base_failed_pw ))
delta_invalid_user=$(( cur_invalid_user - base_invalid_user ))
delta_preauth=$(( cur_preauth - base_preauth ))
delta_probe=$(( cur_probe - base_probe ))
delta_blocks=$(( cur_blocks_total - base_blocks_total ))

period_desc="since monitoring began"
if [[ -n "$base_time" ]]; then
  period_desc="since ${base_time}"
fi

# Build the currently-blocked-IPs list (point-in-time snapshot, not a delta)
blocked_list=""
total_blocked=0
if [[ -s "$RECORD_FILE" ]]; then
  total_blocked="$(wc -l < "$RECORD_FILE" | tr -d '[:space:]')"
  while IFS='|' read -r ip ts reason; do
    [[ -z "$ip" ]] && continue
    entry="• ${ip} — ${reason}"
    if (( ${#blocked_list} + ${#entry} > 900 )); then
      blocked_list="${blocked_list}
…and more (see: sudo block-ip.sh list)"
      break
    fi
    if [[ -n "$blocked_list" ]]; then
      blocked_list="${blocked_list}
${entry}"
    else
      blocked_list="$entry"
    fi
  done < "$RECORD_FILE"
fi
[[ -z "$blocked_list" ]] && blocked_list="(none)"

compute_mention "$MENTION_ON_REPORT"

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host_label="$(hostname)"

curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d @- >/dev/null <<PAYLOAD
{
  "content": "${MENTION_CONTENT}",
  "allowed_mentions": ${MENTION_ALLOWED_JSON},
  "embeds": [{
    "title": "📊 SSH Guard Report",
    "color": 3447003,
    "description": "$(json_escape "Summary ${period_desc} for ${host_label}")",
    "fields": [
      {"name": "Failed password attempts", "value": "${delta_failed_pw}", "inline": true},
      {"name": "Invalid user attempts", "value": "${delta_invalid_user}", "inline": true},
      {"name": "Preauth disconnects", "value": "${delta_preauth}", "inline": true},
      {"name": "Unauthenticated probes", "value": "${delta_probe}", "inline": true},
      {"name": "New IPs blocked", "value": "${delta_blocks}", "inline": true},
      {"name": "Total IPs currently blocked", "value": "${total_blocked}", "inline": true},
      {"name": "Currently blocked IPs", "value": "$(json_escape "$blocked_list")", "inline": false}
    ],
    "timestamp": "${now_ts}"
  }]
}
PAYLOAD

# Update the baseline so the next report reports the *next* period, not
# a growing all-time total.
cat > "$BASELINE_FILE" <<EOF
base_failed_pw=${cur_failed_pw}
base_invalid_user=${cur_invalid_user}
base_preauth=${cur_preauth}
base_probe=${cur_probe}
base_blocks_total=${cur_blocks_total}
base_time="${now_ts}"
EOF
REPORT_SCRIPT_EOF
chmod 700 /usr/local/bin/ssh-guard-report.sh
chown root:root /usr/local/bin/ssh-guard-report.sh

# ---------- cron schedule for the report ----------
echo "==> Installing /etc/cron.d/ssh-guard-report"
cat > /etc/cron.d/ssh-guard-report <<CRON_EOF
# ssh-guard periodic report. Schedule below is set from REPORT_CRON at install
# time; the script itself checks REPORT_ENABLED in config.conf and no-ops if
# disabled, so it's safe to leave this file in place either way.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${REPORT_CRON} root /usr/local/bin/ssh-guard-report.sh >/dev/null 2>&1
CRON_EOF
chmod 644 /etc/cron.d/ssh-guard-report

# ---------- systemd unit ----------
echo "==> Installing /etc/systemd/system/ssh-discord-notify.service"
cat > /etc/systemd/system/ssh-discord-notify.service <<UNIT_EOF
[Unit]
Description=SSH login attempt notifier + auto-block (Discord)
After=network-online.target ${SSHD_UNIT}.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/local/bin/block-ip.sh sync
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
# Note: block-ip.sh sync already ran automatically as part of the service
# starting (see ExecStartPre in the unit file), reconciling any previously
# recorded blocks with the live firewall.

echo "==> Sending a test message to Discord..."
curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK_URL" -d '{
  "embeds": [{
    "title": "🔧 SSH Guard Installed",
    "color": 3447003,
    "description": "This host will now report SSH login attempts, auto-block IPs after repeated failures, and (if enabled) send periodic summary reports.",
    "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
  }]
}' >/dev/null || echo "Warning: test message failed to send. Double-check the webhook URL." >&2

cat <<DONE

Installed successfully.

  Config:      sudo nano /etc/ssh-guard/config.conf   (then: sudo systemctl restart ssh-discord-notify)
  Logs:        sudo journalctl -u ssh-discord-notify -f
  Restart:     sudo systemctl restart ssh-discord-notify
  Blocked IPs: sudo block-ip.sh list
  Live rules:  sudo block-ip.sh rules
  Settings:    sudo block-ip.sh config
  Manual block:   sudo block-ip.sh add <ip> "reason"
  Manual unblock: sudo block-ip.sh remove <ip>
  Run a report now: sudo ssh-guard-report.sh   (no-ops unless REPORT_ENABLED=true)

  Uninstall:
    sudo systemctl disable --now ssh-discord-notify
    sudo rm -f /usr/local/bin/ssh-discord-notify.sh /usr/local/bin/block-ip.sh \\
      /usr/local/bin/ssh-guard-report.sh /etc/systemd/system/ssh-discord-notify.service \\
      /etc/cron.d/ssh-guard-report
    sudo rm -rf /etc/ssh-guard /var/lib/ssh-guard
    sudo systemctl daemon-reload

DONE
