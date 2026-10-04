#!/bin/bash
# ============================================================
# bili-cdn-fix.sh (macOS)
# Test bilibili overseas CDN node IPs, pin the fastest into /etc/hosts.
# Usage:   sudo bash bili-cdn-fix.sh
# Undo:    sudo bash bili-cdn-fix.sh --restore
# ============================================================
set -u
MARKER="# BiliCdnFix"
HOSTS=${BILI_HOSTS:-/etc/hosts}
DOMAINS=${BILI_DOMAINS:-"upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com upos-sz-mirrorcosov.bilivideo.com"}

MODE=run
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) export BILI_DRY_RUN=1 ;;
        --restore) MODE=restore ;;
        --help|-h)
            echo "Usage: bash $0 [--dry-run | --restore]"
            echo "Prepare fresh media with python3 tools/media-urls.py BVID first."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ] && [ "${BILI_DRY_RUN:-0}" != 1 ]; then
    echo "Please repeat this command with sudo, or add --dry-run."
    exit 1
fi

flush_dns() { dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; }

if [ "$MODE" = restore ]; then
    [ "${BILI_DRY_RUN:-0}" = 1 ] && { echo "Dry run: hosts unchanged"; exit 0; }
    cp -p "$HOSTS" "$HOSTS.bak_$(date +%Y%m%d_%H%M%S)_restore" || exit 1
    sed -i '' "/$MARKER/d" "$HOSTS" || exit 1
    flush_dns
    echo "Restored: all BiliCdnFix entries removed."
    exit 0
fi

candidates_for() {
    case "$1" in
    upos-hz-mirrorakam.akamaized.net)
        echo "23.48.96.104 23.48.96.113 203.153.17.248 202.130.202.19 202.130.202.40 23.45.207.170 23.45.207.172 23.62.212.66 23.62.212.110 23.62.212.101 23.62.212.99 23.62.212.67 23.62.212.68 23.62.212.93 23.62.212.106 23.220.71.197 23.220.71.186 23.49.104.199 23.49.104.213 23.211.60.70 23.211.60.78 203.186.47.73 203.186.47.74 203.186.47.147 203.186.47.160 203.186.47.162 23.47.48.104 23.47.48.84 23.47.48.68 23.47.48.78 23.47.48.120 23.49.5.40 23.49.5.18 23.215.0.36 23.215.0.43 23.215.0.44 23.215.0.46 23.202.34.240 23.202.34.248 2.19.117.132 2.19.117.148 2.16.154.161 2.16.154.98 5.178.42.226 5.178.42.163" ;;
    upos-sz-mirroraliov.bilivideo.com)
        echo "47.246.41.174 47.246.41.175 47.246.41.176 47.246.41.177 47.246.41.178 163.181.81.231 163.181.81.233 163.181.81.236 163.181.35.183 163.181.35.184 163.181.35.180 163.181.35.186 163.181.35.187 155.102.4.4 155.102.4.5 155.102.4.6 155.102.4.22 155.102.4.141 155.102.4.142 155.102.4.144 155.102.4.145 155.102.4.146 155.102.4.147 163.181.78.183 163.181.78.184 163.181.78.186 163.181.1.227 163.181.60.219 163.181.60.220 47.246.38.202 47.246.38.203 47.246.38.204 47.246.38.205 155.102.60.29 155.102.60.30 155.102.60.31" ;;
    upos-sz-mirrorcosov.bilivideo.com) echo "${BILI_COSOV_IPS:-}" ;;
    esac
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BILI_MEDIA_DIR=${BILI_MEDIA_DIR:-"$SCRIPT_DIR/../media"}
. "$SCRIPT_DIR/../common/download-speed.sh"
if [ "$DRY_RUN" != 1 ]; then
    BACKUP="$HOSTS.bak_$(date +%Y%m%d_%H%M%S)"
    cp -p "$HOSTS" "$BACKUP" || exit 1
    scutil --dns > "$BACKUP.dns.txt" || exit 1
    networksetup -listallnetworkservices > "$BACKUP.network-services.txt" || exit 1
    networksetup -getdnsservers "${BILI_NETWORK_SERVICE:-Wi-Fi}" > "$BACKUP.dns-servers.txt" || exit 1
fi
speed_init || exit 1
echo "Download test: $SPEED_ROUNDS rounds per media, up to $SPEED_BYTES bytes each; failed domains remain unchanged."


NEW_LINES=""
SUCCESS_DOMAINS=""

for domain in $DOMAINS; do
    echo ""
    echo "Testing nodes for $domain ..."
    best_ip=""; best_speed=0
    for ip in $(printf '%s\n%s\n' "${BILI_CANDIDATE_IPS:-$(candidates_for "$domain")}" "$(resolve_extra "$domain")" | tr ' ' '\n' | sort -u); do
        [ -n "$ip" ] || continue
        speed=$(measure "$domain" "$ip")
        [ -n "$speed" ] || continue
        printf "  %-16s %9s bytes/s\n" "$ip" "$speed"
        if [ "$speed" -gt "$best_speed" ]; then best_speed=$speed; best_ip=$ip; fi
    done
    if [ -n "$best_ip" ]; then
        echo "  BEST: $best_ip  ${best_speed} bytes/s"
        SUCCESS_DOMAINS="$SUCCESS_DOMAINS $domain"
        NEW_LINES="$NEW_LINES$best_ip $domain $MARKER (${best_speed} bytes/s, $(date +%Y-%m-%d))\n"
    else
        echo "  No reachable node found, skipping."
    fi
done

if [ -z "$NEW_LINES" ]; then
    echo "Nothing to write."
    exit 1
fi

[ "$DRY_RUN" = 1 ] && { printf '%b' "$NEW_LINES"; exit 0; }
TMP=$(mktemp) || exit 1
# Preserve unrelated and failed-domain entries, including prior pins.
awk -v domains="$SUCCESS_DOMAINS" 'BEGIN{split(domains,a," "); for(i in a) d[a[i]]=1}
    {drop=0; for(i=2;i<=NF;i++){if($i ~ /^#/) break; if($i in d) drop=1} if(!drop) print}' "$HOSTS" > "$TMP"
printf '%b' "$NEW_LINES" >> "$TMP"
cat "$TMP" > "$HOSTS" || { rm -f "$TMP"; exit 1; }
rm -f "$TMP"
flush_dns

echo ""
echo "Done! /etc/hosts updated (backup saved next to it)."
echo "Re-run anytime to re-test; --restore to undo."
