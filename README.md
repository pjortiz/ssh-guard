# SSH Guard — Discord Login Notifications + Auto-Block

Watches SSH login attempts on your VPS and posts a Discord notification for
every success/failure, including the source IP (and optional GeoIP location).
After too many failed attempts from the same IP within a time window, it can
automatically block that IP using whatever firewall you already have running
(`ufw`, `firewalld`, `nftables`, or `iptables`).

## What gets installed

| File | Purpose |
|---|---|
| `/etc/ssh-guard/config.conf` | Shared settings: webhook URL, thresholds, etc. |
| `/usr/local/bin/ssh-discord-notify.sh` | Tails the SSH journal, sends Discord embeds, triggers auto-block |
| `/usr/local/bin/block-ip.sh` | Manual/automatic IP block, unblock, list, status |
| `/etc/systemd/system/ssh-discord-notify.service` | Keeps the notifier running and restarts it on crash/reboot |
| `/etc/ssh-guard/blocked_ips.list` | Record of currently blocked IPs and why |
| `/var/lib/ssh-guard/fail_attempts.log` | Rolling window of recent failed-login timestamps per IP (used for auto-block) |
| `/var/lib/ssh-guard/lifetime_fail_counts.tsv` | All-time failed-login count per IP, never pruned |

## Requirements

- A systemd-based Linux distro (Debian, Ubuntu, RHEL/CentOS/Fedora/Rocky, etc.)
- `curl`, `systemctl`, `journalctl` (present on virtually all modern distros)
- One of: `ufw`, `firewalld`, `nftables`, or `iptables` — for auto-block/`block-ip.sh` to work. The notifier itself works without any of these.
- A Discord webhook URL (Server Settings → Integrations → Webhooks → New Webhook)

## Install

Host `install.sh` in your repo, then on the VPS run it as root:

```bash
curl -fsSL https://raw.githubusercontent.com/pjortiz/ssh-guard/refs/heads/main/install-ssh-guard.sh | sudo bash
```

You'll be prompted for:

- Your Discord webhook URL
- Whether to include GeoIP lookups in notifications
- Whether to auto-block IPs after repeated failures
- The failure threshold and time window for auto-block

### Non-interactive install

Useful for provisioning scripts, Ansible, cloud-init, etc.:

```bash
curl -fsSL https://raw.githubusercontent.com/pjortiz/ssh-guard/refs/heads/main/install-ssh-guard.sh | sudo \
  WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy" \
  DO_GEOIP=true \
  AUTO_BLOCK=true \
  FAIL_THRESHOLD=5 \
  FAIL_WINDOW=600 \
  bash
```

Any variable you export ahead of time is used as-is; anything left unset falls
back to an interactive prompt (read from `/dev/tty`, so this works fine even
though stdin is occupied by the piped script) or its default.

The installer also:
- Auto-detects whether your distro's sshd unit is `ssh` or `sshd`
- Validates the webhook URL looks legitimate before writing anything
- Enables and starts the systemd service, and confirms it actually started
- Sends a one-time "installed" test message to Discord

## What you'll see in Discord

- ✅ **SSH Login Succeeded** — host, user, source IP, location
- ❌ **SSH Login Failed** — host, user, source IP, location, the current attempt count within the failure window, and the all-time (lifetime) failed-attempt count for that IP
- ⚠️ **SSH Connection Closed (preauth)** — connection dropped before completing authentication
- 🚫 **IP Blocked** — fired by `block-ip.sh`, whether triggered manually or automatically
- ✅ **IP Unblocked** — fired by `block-ip.sh remove`

## Configuration

Edit `/etc/ssh-guard/config.conf`, then restart the service:

```bash
sudo nano /etc/ssh-guard/config.conf
sudo systemctl restart ssh-discord-notify
```

| Setting | Default | Description |
|---|---|---|
| `WEBHOOK_URL` | — | Your Discord webhook URL |
| `SSHD_UNIT` | `ssh` | systemd unit name for sshd (`ssh` or `sshd`) |
| `DO_GEOIP` | `true` | Look up rough city/region/country per IP via ip-api.com |
| `AUTO_BLOCK` | `true` | Automatically block an IP after too many failures |
| `FAIL_THRESHOLD` | `5` | Failed attempts (per IP) before auto-block fires |
| `FAIL_WINDOW` | `600` | Time window in seconds for the above |

This file contains your webhook URL, so it's created with `chmod 600` (root-only read). Keep it that way.

## Managing blocked IPs

```bash
sudo block-ip.sh add 203.0.113.7 "repeated failed SSH logins"
sudo block-ip.sh remove 203.0.113.7
sudo block-ip.sh list
sudo block-ip.sh status 203.0.113.7
sudo block-ip.sh sync   # reapply every recorded IP to the live firewall
sudo block-ip.sh config # show current settings + firewall backend + block count
sudo block-ip.sh rules  # show the ACTUAL live firewall rules blocking IPs
```

`block-ip.sh` works standalone too — if `/etc/ssh-guard/config.conf` doesn't
exist or has no `WEBHOOK_URL`, it just skips the Discord notification and
blocks/unblocks silently.

`sudo block-ip.sh config` shows the current settings, active firewall
backend, and how many IPs are currently recorded as blocked — the webhook URL
is partially masked in the output, since it's a secret.

`sudo block-ip.sh rules` shows the actual, live rules from the firewall
itself (not this script's record file) — the real source of truth for what's
currently being dropped. Useful for confirming a block really took effect, or
spotting drift between what `list` reports and what the firewall is actually
doing:

- **ufw** → `ufw status numbered`
- **firewalld** → the active zone's rich rules
- **nftables** → the `blocked_ips` set and its containing table
- **iptables** → the `DROP` rules in the `INPUT` chain

`block-ip.sh status <ip>` also prints the all-time failed-login count for that
IP if one exists in `/var/lib/ssh-guard/lifetime_fail_counts.tsv`, even if the
IP isn't currently blocked.

### Persistence across reboots

Rule persistence depends on your firewall backend:

- **ufw / firewalld** — rules persist automatically.
- **nftables** — save your ruleset explicitly, e.g. `nft list ruleset > /etc/nftables.conf` (path/mechanism varies by distro), and make sure it's loaded at boot.
- **iptables** — rules do **not** survive a reboot on their own. Install `iptables-persistent` (Debian/Ubuntu: `apt install iptables-persistent`) and run `netfilter-persistent save` after blocking, or use a cron/systemd hook to persist on change.

## Operations

```bash
# Live logs
sudo journalctl -u ssh-discord-notify -f

# Restart after editing config
sudo systemctl restart ssh-discord-notify

# Check service status
sudo systemctl status ssh-discord-notify
```

## Rerunning the installer

Rerunning `install.sh` is safe and won't disrupt existing state:

- `/usr/local/bin/ssh-discord-notify.sh` and `block-ip.sh` are overwritten cleanly (no duplication).
- `/etc/ssh-guard/blocked_ips.list`, `/var/lib/ssh-guard/fail_attempts.log`, and `/var/lib/ssh-guard/lifetime_fail_counts.tsv` are never touched — block history and lifetime counts survive.
- If a config already exists at `/etc/ssh-guard/config.conf`, its current values (webhook URL, thresholds, etc.) are offered as the defaults in each prompt — hit Enter to keep them, or type a new value to change just that one setting.

## Firewall reconciliation (sync)

Firewall rule persistence isn't always guaranteed by the firewall itself — most
notably, plain `iptables` rules do **not** survive a reboot without
`iptables-persistent` installed and configured (see the note below). Without
reconciliation, `blocked_ips.list` could end up saying an IP is blocked when
the actual firewall no longer has that rule.

To prevent that, the systemd unit runs `block-ip.sh sync` automatically via
`ExecStartPre` **every time the service starts** — on boot, on
`systemctl restart`, and after a crash-triggered restart — not just during
install. It reapplies every IP in `blocked_ips.list` to the live firewall, so
recorded state and actual firewall state can't silently drift apart for long.
This step is best-effort (prefixed with `-` in the unit file) so a sync
failure never prevents the notifier itself from starting.

You can also run it manually any time:

```bash
sudo block-ip.sh sync
```

## Uninstall

```bash
sudo systemctl disable --now ssh-discord-notify
sudo rm -f /usr/local/bin/ssh-discord-notify.sh /usr/local/bin/block-ip.sh \
  /etc/systemd/system/ssh-discord-notify.service
sudo rm -rf /etc/ssh-guard /var/lib/ssh-guard
sudo systemctl daemon-reload
```

Note: this removes the block-ip record and config, but does **not** automatically
remove any IPs you've already blocked from your firewall — unblock them first
with `sudo block-ip.sh remove <ip>` if you want them cleared, or manage that
firewall's rules directly afterward.

## How it works

- The notifier tails `journalctl -fu <SSHD_UNIT>` rather than parsing
  `/var/log/auth.log` directly, so it works the same way across distros that
  route sshd logs through systemd's journal.
- It matches on the log lines sshd already emits (`Accepted ... from <ip>`,
  `Failed password ... from <ip>`) rather than hooking into PAM, which keeps
  it simple and catches both password and public-key auth.
- Failed attempts are recorded per-IP with a timestamp in
  `/var/lib/ssh-guard/fail_attempts.log`; on each new failure, entries older
  than `FAIL_WINDOW` are pruned and the remaining count for that IP is
  checked against `FAIL_THRESHOLD`.
- Separately, a simple all-time counter per IP is kept in
  `/var/lib/ssh-guard/lifetime_fail_counts.tsv` (never pruned) so you can see
  whether an IP is a first-time offender or a repeat one, even outside the
  current auto-block window.
- When the threshold is hit, the notifier calls `block-ip.sh add <ip> "..."`,
  which is idempotent (blocking an already-blocked IP is a no-op) and handles
  sending its own Discord notification for the block event.

## Security notes

- `/etc/ssh-guard/config.conf` contains your webhook URL in plaintext —
  it's `chmod 600` by default; don't loosen that.
- Auto-blocking is based on log pattern matching, not authentication
  internals — review `FAIL_THRESHOLD` carefully if you have automated
  systems/scripts that legitimately retry SSH connections, to avoid
  locking yourself out.
- Always keep at least one root/console access path (VPS provider's web
  console, a separate admin IP allowlist, etc.) in case you accidentally
  block your own IP.
