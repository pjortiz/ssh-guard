# SSH Guard — Discord Login Notifications + Auto-Block + Reports

Watches SSH login attempts on your VPS and posts a Discord notification for
every success/failure, including the source IP (and optional GeoIP location).
After too many failed attempts from the same IP within a time window, it can
automatically block that IP using whatever firewall you already have running
(`ufw`, `firewalld`, `nftables`, or `iptables`). It can also send periodic
Discord summary reports on a cron schedule, and ping `@everyone`, a role, or
a specific user on any notification type.

## What gets installed

| File | Purpose |
|---|---|
| `/etc/ssh-guard/config.conf` | Shared settings: webhook URL, thresholds, mentions, report schedule |
| `/usr/local/bin/ssh-discord-notify.sh` | Tails the SSH journal, sends Discord embeds, triggers auto-block |
| `/usr/local/bin/block-ip.sh` | Manual/automatic IP block, unblock, list, status |
| `/usr/local/bin/ssh-guard-report.sh` | Sends the periodic Discord summary report |
| `/etc/systemd/system/ssh-discord-notify.service` | Keeps the notifier running and restarts it on crash/reboot |
| `/etc/cron.d/ssh-guard-report` | Cron schedule for the periodic report (self-gates on `REPORT_ENABLED`) |
| `/etc/ssh-guard/blocked_ips.list` | Record of currently blocked IPs and why |
| `/var/lib/ssh-guard/fail_attempts.log` | Rolling window of recent failed-login timestamps per IP (used for auto-block) |
| `/var/lib/ssh-guard/lifetime_fail_counts.tsv` | All-time failed-login count per IP, never pruned |
| `/var/lib/ssh-guard/counter_*.count` | Running totals (failed password, invalid user, preauth, probes, blocks) used to compute report deltas |
| `/var/lib/ssh-guard/report_baseline.tsv` | Snapshot of the counters above as of the last report, so each report shows only what happened since then |

## Requirements

- A systemd-based Linux distro (Debian, Ubuntu, RHEL/CentOS/Fedora/Rocky, etc.)
- `curl`, `systemctl`, `journalctl` (present on virtually all modern distros)
- One of: `ufw`, `firewalld`, `nftables`, or `iptables` — for auto-block/`block-ip.sh` to work. The notifier itself works without any of these.
- A cron daemon (`cron`/`crond`) if you want periodic reports to run automatically — otherwise you can still run `ssh-guard-report.sh` manually
- A Discord webhook URL (Server Settings → Integrations → Webhooks → New Webhook)

## Install

Host `install-ssh-guard.sh` in your repo, then on the VPS run it as root:

```bash
curl -fsSL https://raw.githubusercontent.com/pjortiz/ssh-guard/refs/heads/main/install-ssh-guard.sh | sudo bash
```

You'll be prompted for:

- Your Discord webhook URL
- Whether to include GeoIP lookups in notifications
- Whether to auto-block IPs after repeated failures, and the threshold/window
- Whether to send a Discord message for every individual failed attempt, or stay quiet until a block actually happens
- Whether to send a Discord message when an IP gets blocked
- A default `@mention` target applied to all notification types (`none` / `everyone` / `role:<id>` / `user:<id>`) — see [Mentions](#mentions) below for fine-tuning this per notification type
- Whether to enable periodic summary reports, and their cron schedule

### Non-interactive install

Useful for provisioning scripts, Ansible, cloud-init, etc.:

```bash
curl -fsSL https://raw.githubusercontent.com/pjortiz/ssh-guard/refs/heads/main/install-ssh-guard.sh | sudo \
  WEBHOOK_URL="https://discord.com/api/webhooks/xxx/yyy" \
  DO_GEOIP=true \
  AUTO_BLOCK=true \
  FAIL_THRESHOLD=5 \
  FAIL_WINDOW=600 \
  NOTIFY_FAILED_ATTEMPTS=true \
  NOTIFY_ON_BLOCK=true \
  MENTION_DEFAULT=none \
  REPORT_ENABLED=false \
  REPORT_CRON="0 8 * * *" \
  bash
```

Any variable you export ahead of time is used as-is; anything left unset falls
back to an interactive prompt (read from `/dev/tty`, so this works fine even
though stdin is occupied by the piped script) or its default.

The installer also:
- Auto-detects whether your distro's sshd unit is `ssh` or `sshd`
- Validates the webhook URL looks legitimate before writing anything
- Enables and starts the systemd service, and confirms it actually started
- Installs the cron schedule for reports (harmless even if reports are disabled — the report script checks `REPORT_ENABLED` itself and no-ops)
- Sends a one-time "installed" test message to Discord

## What you'll see in Discord

- ⚠️ **SSH Login Succeeded** — host, user, source IP, location. Uses a warning icon and orange color, not a green checkmark — on purpose. A successful login is exactly the event you want to notice immediately: it might be you, or it might be an intrusion. Always sent regardless of `NOTIFY_FAILED_ATTEMPTS`.
- ❌ **SSH Login Failed** — host, user, source IP, location, the current attempt count within the failure window, and the all-time (lifetime) failed-attempt count for that IP. Fires for both a wrong password on a real account and a login attempt against a username that doesn't exist at all (`Invalid user`). Suppressed if `NOTIFY_FAILED_ATTEMPTS=false`, **unless** that IP's lifetime failure count already exceeds `FAIL_THRESHOLD` — repeat offenders always get surfaced.
- ⚠️ **SSH Connection Closed (preauth)** — the client attempted a real username, then disconnected before completing authentication. Same suppression rule and repeat-offender exception as above.
- 🚫 **IP Blocked** — fired by `block-ip.sh`, whether triggered manually or automatically. Can be turned off with `NOTIFY_ON_BLOCK=false` if you'd rather the block just happen silently (the IP still gets blocked either way — this only controls the notification).
- ✅ **IP Unblocked** — fired by `block-ip.sh remove`. Always sent.
- 📊 **SSH Guard Report** — a periodic summary, if `REPORT_ENABLED=true`. See [Periodic reports](#periodic-reports) below.

### A note on "bare" preauth connection closes

Most raw internet scanning traffic hits your server, sends nothing at all
(not even a username), and disconnects — sshd logs this as a plain
`Connection closed by <ip> port <port> [preauth]` with no `authenticating
user` in it. This is genuinely not a login attempt, so it's **never
notified individually** (it would be constant noise from every scanner on
the internet) — but it *is* counted, and shows up as "Unauthenticated
probes" in the periodic report so you can still see the scale of scan
traffic hitting the box. If you were expecting to see a preauth alert for
every disconnected connection and aren't, this is almost always why.

## Mentions

Every notification type can optionally ping `@everyone`, a specific role, or
a specific user. Configure this per type in `/etc/ssh-guard/config.conf`:

| Setting | Controls |
|---|---|
| `MENTION_ON_FAILURE` | Failed login / invalid user / preauth-close notifications |
| `MENTION_ON_SUCCESS` | Successful login notifications |
| `MENTION_ON_BLOCK` | IP Blocked notifications |
| `MENTION_ON_UNBLOCK` | IP Unblocked notifications |
| `MENTION_ON_REPORT` | Periodic report notifications |

Each accepts one of:

- `none` (default) — no mention
- `everyone` — pings `@everyone`
- `role:<role_id>` — pings a specific Discord role, e.g. `role:123456789012345678`
- `user:<user_id>` — pings a specific Discord user, e.g. `user:987654321098765432`

To find a role or user ID, enable Developer Mode in Discord (User Settings →
Advanced), then right-click the role or user and choose "Copy ID".

The installer's `MENTION_DEFAULT` prompt sets all five of these to the same
value for convenience — edit `config.conf` directly afterward if you want,
say, `@everyone` on blocks but nothing on routine failures. **Note:**
rerunning the installer will overwrite all five with whatever you answer at
that prompt, even if you'd customized them individually — so if you've
fine-tuned per-type mentions, skip the reinstall and just edit `config.conf`
by hand instead.

## Periodic reports

Set `REPORT_ENABLED=true` (via the installer prompt or directly in
`config.conf`) to get a recurring Discord summary on the schedule in
`REPORT_CRON` (standard 5-field cron syntax, default `0 8 * * *` — daily at
8am server time). Each report shows counts **since the previous report**
(not an ever-growing all-time total):

- Failed password attempts
- Invalid user attempts
- Preauth disconnects
- Unauthenticated probes
- New IPs blocked
- Total IPs currently blocked

For the actual list of which IPs are blocked and why, use `sudo block-ip.sh
list` — the report intentionally only shows the count, not the full list, to
keep it short and avoid the report growing unwieldy as more IPs accumulate.

You can run it manually any time, regardless of the cron schedule or even if
reports are disabled entirely for testing:

```bash
sudo ssh-guard-report.sh
```

Note this will exit silently and do nothing if `REPORT_ENABLED` isn't `true`
in `config.conf` — that's intentional, so the cron job can stay installed
permanently without needing to be added/removed as you toggle the setting.

To change the schedule after install, either edit
`/etc/cron.d/ssh-guard-report` directly (the schedule is the first 5 fields
of the last line), or re-run the installer with a new `REPORT_CRON` value.

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
| `NOTIFY_FAILED_ATTEMPTS` | `true` | Send a Discord message for every individual failed/preauth attempt. Set to `false` to stay quiet on each attempt while still counting them, tracking the lifetime counter, and auto-blocking — you'll just get the single "IP Blocked" message once a block actually happens. **Exception:** once an IP's lifetime failed-attempt count exceeds `FAIL_THRESHOLD`, per-attempt notifications for that IP always fire regardless of this setting — see below. |
| `NOTIFY_ON_BLOCK` | `true` | Send a Discord message when an IP gets blocked. The block itself always happens either way — this only controls the notification. |
| `NOTIFY_ON_UNBLOCK` | `true` | Send a Discord message when an IP gets unblocked. |
| `MENTION_ON_FAILURE` / `MENTION_ON_SUCCESS` / `MENTION_ON_BLOCK` / `MENTION_ON_UNBLOCK` / `MENTION_ON_REPORT` | `none` | `@mention` target per notification type — see [Mentions](#mentions) above. |
| `REPORT_ENABLED` | `false` | Send periodic Discord summary reports — see [Periodic reports](#periodic-reports) above. |
| `REPORT_CRON` | `0 8 * * *` | Cron schedule for the report. |

This file contains your webhook URL, so it's created with `chmod 600` (root-only read). Keep it that way.

### Repeat-offender escalation

`NOTIFY_FAILED_ATTEMPTS=false` is meant to quiet down routine scanner noise,
not hide a genuinely persistent attacker. So there's one built-in override:
once a given IP's **lifetime** failed-attempt count exceeds `FAIL_THRESHOLD`,
every subsequent failed/preauth notification from that IP fires regardless of
`NOTIFY_FAILED_ATTEMPTS`. This matters most if you run with `AUTO_BLOCK=false`
(so the IP is never actually blocked) — without this override, a determined
attacker could keep retrying indefinitely in total silence.

**This override never applies to an IP that's already blocked.** A rapid
burst of attempts can easily push the attempt count past `FAIL_THRESHOLD`
before the block finishes taking effect — in-flight connections, or an
attacker reconnecting faster than the firewall rule propagates — which
would otherwise cause a string of "6/5", "7/5", etc. failed-attempt
notifications right after the block, bypassing `NOTIFY_FAILED_ATTEMPTS=false`
on every single one even though the "IP Blocked" notification already
covered it. Once `block-ip.sh` has recorded the IP as blocked, any further
attempts from it go back to following `NOTIFY_FAILED_ATTEMPTS` normally (so
with it set to `false`, they stay silent) — the escalation override only
matters for IPs that aren't blocked yet.

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

`sudo block-ip.sh config` shows the current settings (including mentions,
notification toggles, and report settings), active firewall backend, and how
many IPs are currently recorded as blocked — the webhook URL is partially
masked in the output, since it's a secret.

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

# Send a report right now, ignoring the cron schedule
sudo ssh-guard-report.sh
```

## Rerunning the installer

Rerunning `install-ssh-guard.sh` is safe and won't disrupt existing state:

- `/usr/local/bin/ssh-discord-notify.sh`, `block-ip.sh`, and `ssh-guard-report.sh` are overwritten cleanly (no duplication).
- `/etc/ssh-guard/blocked_ips.list`, `/var/lib/ssh-guard/fail_attempts.log`, `/var/lib/ssh-guard/lifetime_fail_counts.tsv`, the report counters, and the report baseline are never touched — block history, lifetime counts, and report period tracking all survive.
- If a config already exists at `/etc/ssh-guard/config.conf`, its current values (webhook URL, thresholds, etc.) are offered as the defaults in each prompt — hit Enter to keep them, or type a new value to change just that one setting.
- **Exception:** the `MENTION_DEFAULT` prompt always overwrites all five `MENTION_ON_*` settings together — see [Mentions](#mentions) above.

## Firewall reconciliation (sync)

Firewall rule persistence isn't always guaranteed by the firewall itself — most
notably, plain `iptables` rules do **not** survive a reboot without
`iptables-persistent` installed and configured (see the note above). Without
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
  /usr/local/bin/ssh-guard-report.sh /etc/systemd/system/ssh-discord-notify.service \
  /etc/cron.d/ssh-guard-report
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
  `Failed password ... from <ip>`, `Invalid user ... from <ip>`) rather than
  hooking into PAM, which keeps it simple and catches password auth,
  public-key auth, and invalid-username rejections alike.
- Failed attempts are recorded per-IP with a timestamp in
  `/var/lib/ssh-guard/fail_attempts.log`; on each new failure, entries older
  than `FAIL_WINDOW` are pruned and the remaining count for that IP is
  checked against `FAIL_THRESHOLD`.
- Separately, a simple all-time counter per IP is kept in
  `/var/lib/ssh-guard/lifetime_fail_counts.tsv` (never pruned) so you can see
  whether an IP is a first-time offender or a repeat one, even outside the
  current auto-block window.
- A second, independent set of global counters (`/var/lib/ssh-guard/counter_*.count`)
  tracks aggregate totals — not per-IP — purely to feed the periodic report.
  These increment regardless of `NOTIFY_FAILED_ATTEMPTS`, so the report stays
  accurate even when individual notifications are muted.
- When the threshold is hit, the notifier calls `block-ip.sh add <ip> "..."`,
  which is idempotent (blocking an already-blocked IP is a no-op) and handles
  sending its own Discord notification for the block event (subject to
  `NOTIFY_ON_BLOCK`).

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
- If you use `MENTION_ON_*=everyone`, make sure the webhook's channel
  actually permits `@everyone` mentions for the account that owns the
  webhook — otherwise Discord will silently deliver the message without
  the ping actually notifying anyone.
