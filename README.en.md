# bili-cdn-pin

**An automated fix for Bilibili lag overseas: measure the fastest CDN node and pin it, so videos stop buffering.**

English (AU) | [中文](README.md)

## What problem does it solve

Bilibili serves videos to overseas users through these domains:

```
upos-hz-mirrorakam.akamaized.net    (Akamai)
upos-sz-mirroraliov.bilivideo.com   (Alibaba Cloud overseas)
upos-sz-mirrorcosov.bilivideo.com  (Tencent Cloud overseas)
```

These CDNs have plenty of nodes around the world, but the scheduler often resolves you onto a far / overloaded / dead node — even when a 3ms local node sits right in your city. (Real case: an Aussie gigabit fibre line returned 0 Mbps across the board on the default source; after pinning a local node it hit 571 Mbps.) First confirm your lag is actually this type: see the [Diagnosis Guide](docs/diagnosis.md) (in Chinese).

This branch downloads video and audio three times per candidate, up to 32 MiB per request. It selects by the lower of their median download speeds, with normal TLS validation. Server/router health checks retain a pin when both medians reach 5 MB/s. Only these three exact domains are affected. See [download testing](docs/download-speed.md) for parameters and limitations.

## Quick start

### Local mode (hosts, this PC only)

Just run it again whenever things stall — no schedule needed:

```powershell
# Windows: right-click → "Run with PowerShell" (it auto-prompts for admin); to undo add -Restore
python tools/media-urls.py BV1Ra4y117kf --video-codec hevc
windows\bili-cdn-fix.ps1
```

```bash
# macOS: fresh media, then measure without changing hosts/DNS
python3 tools/media-urls.py BV1Ra4y117kf --video-codec hevc &&
bash macos/bili-cdn-fix.sh --dry-run
```

To install, refresh the media and run `sudo bash macos/bili-cdn-fix.sh`; it backs up hosts/DNS before testing and writes only successful domains. To undo, run `sudo bash macos/bili-cdn-fix.sh --restore`. Python 3 and curl are required. The media tool automatically falls back to the public page-list API if the view API fails. HEVC avoids incomplete responses observed for some AVC test resources; this setting does not change the player codec. URLs expire: refresh them before every run. Cold-cache speed can be much lower than repeated-download speed.

### Server mode (whole household, recommended)

Run [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) on any always-on device as the household DNS. The script tests speed weekly and updates DNS rewrites via the API, so phones / tablets / TVs all benefit:

1. Install AdGuard Home on an always-on device; set the upstream DNS to `1.1.1.1`
2. Point the router's DHCP DNS at this device; set the device's own DNS to `1.1.1.1` (to prevent a loop)
3. Refresh media URLs using the preparation command before each scheduled run, keep the repository directory structure, and deploy the update script (edit the address / username / password at the top), then add a weekly Sunday 04:30 scheduled task:
   - Synology: DSM Task Scheduler, run as root `bash /path/to/server/bili-agh-update.sh >> /path/to/bili-agh.log 2>&1`
   - Mac mini / Debian: `sudo crontab -e` and add `30 4 * * 0 /bin/bash /path/to/server/bili-agh-update.sh >> /path/to/bili-agh.log 2>&1` (remember to disable sleep on macOS)
   - Always-on Windows machine: Task Scheduler to run `windows\bili-agh-update.ps1`
4. Verify: `nslookup upos-hz-mirrorakam.akamaized.net <device IP>` should return the pinned IP

### Router mode (OpenWrt / Merlin, the lightest)

dnsmasq replies to the whole LAN from the router's `/etc/hosts` — no AdGuard needed:

```sh
opkg install curl
# Generate fresh media/*.url on a computer and copy them with the repository before each run.
sh openwrt/bili-openwrt-update.sh
# crontab -e add: 30 4 * * 0 /root/bili-openwrt-update.sh >> /root/bili-cdn.log 2>&1
```

## Directory structure

```
windows/bili-cdn-fix.ps1        Local mode (hosts)
windows/bili-agh-update.ps1     Server mode (AdGuard API, always-on Windows machine)
macos/bili-cdn-fix.sh           Local mode (hosts)
server/bili-agh-update.sh       Server mode (AdGuard API, works on Synology / macOS / Debian)
openwrt/bili-openwrt-update.sh  Router mode (dnsmasq hosts)
docs/                           Diagnosis guide / FAQ / troubleshooting guide (in Chinese)
```

## Documentation

- [Diagnosis Guide](docs/diagnosis.md) — first work out whether you've got "the wrong CDN family" or "the wrong node" (in Chinese)
- [FAQ](docs/faq.md) — update frequency, scope of impact, mobile apps, node failure and other common questions (in Chinese)
- [Troubleshooting Guide](docs/troubleshooting.md) — secondary DNS round-robin, RDNSS leak, IPv6 misconceptions, DoH bypass, Tampermonkey not taking effect, layer-by-layer verification (in Chinese)

## Acknowledgements

- IP seed list and the original idea: [miyouzi/akamTester](https://github.com/miyouzi/akamTester)
- CDN domain switching approach: [Kanda-Akihito-Kun/ccb](https://github.com/Kanda-Akihito-Kun/ccb)

## License

MIT
