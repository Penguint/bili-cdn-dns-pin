#!/bin/sh
# ============================================================
# bili-openwrt-update.sh (OpenWrt / Merlin with dnsmasq)
# Pin fastest bilibili overseas CDN IP into router /etc/hosts.
# dnsmasq serves /etc/hosts entries to ALL LAN clients.
# Requires: curl  (opkg update && opkg install curl)
# Schedule (weekly, Sun 04:30) via: crontab -e
#   30 4 * * 0 /root/bili-openwrt-update.sh >> /root/bili-cdn.log 2>&1
# Undo: sed -i '/# BiliCdnFix/d' /etc/hosts && /etc/init.d/dnsmasq reload
# ============================================================
MARKER="# BiliCdnFix"
HOSTS=${BILI_HOSTS:-/etc/hosts}
KEEP_THRESHOLD_BPS=${BILI_KEEP_BPS:-5000000}
DOMAINS=${BILI_DOMAINS:-"upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com upos-sz-mirrorcosov.bilivideo.com"}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

candidates_for() {
    case "$1" in
    upos-hz-mirrorakam.akamaized.net)
        echo "23.48.96.104 23.48.96.113 203.153.17.248 202.130.202.19 202.130.202.40 23.45.207.170 23.45.207.172 23.62.212.66 23.62.212.110 23.62.212.101 23.62.212.99 23.220.71.197 23.220.71.186 23.49.104.199 23.49.104.213 23.211.60.70 23.211.60.78 203.186.47.73 203.186.47.74 203.186.47.147 203.186.47.160" ;;
    upos-sz-mirroraliov.bilivideo.com)
        echo "163.181.81.231 163.181.81.233 163.181.81.236 163.181.35.183 163.181.35.184 155.102.4.5 155.102.4.6 155.102.4.141 155.102.4.145 163.181.78.183 163.181.78.184 47.246.38.202 47.246.38.203 47.246.41.174 47.246.41.175 47.246.41.176" ;;
    upos-sz-mirrorcosov.bilivideo.com) echo "${BILI_COSOV_IPS:-}" ;;
    esac
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BILI_MEDIA_DIR=${BILI_MEDIA_DIR:-"$SCRIPT_DIR/../media"}
. "$SCRIPT_DIR/../common/download-speed.sh"
[ "${1:-}" = "--restore" ] || speed_init || exit 1

if [ "${1:-}" = "--restore" ]; then
    [ "$DRY_RUN" = 1 ] && { log "Dry run: hosts unchanged"; exit 0; }
    sed -i "/$MARKER/d" "$HOSTS" && /etc/init.d/dnsmasq reload
    exit $?
fi
[ "$DRY_RUN" = 1 ] || cp "$HOSTS" "$HOSTS.bak_$(date +%Y%m%d_%H%M%S)" || exit 1
changed=0
for domain in $DOMAINS; do
    log "=== $domain ==="
    old_ip=$(grep "$MARKER" "$HOSTS" | grep " $domain " | awk '{print $1}' | head -n1)

    if [ -n "$old_ip" ]; then
        old_speed=$(measure "$domain" "$old_ip")
        if [ -n "$old_speed" ] && [ "$old_speed" -ge "$KEEP_THRESHOLD_BPS" ]; then
            log "current $old_ip still good (${old_speed} bytes/s) - keeping"
            continue
        fi
        log "current $old_ip slow or dead (${old_speed:-failed}) - re-testing"
    fi

    best_ip=""; best_speed=0
    for ip in $(printf '%s\n%s\n' "${BILI_CANDIDATE_IPS:-$(candidates_for "$domain")}" "$(resolve_extra "$domain")" | tr ' ' '\n' | sort -u); do
        [ -n "$ip" ] || continue
        speed=$(measure "$domain" "$ip")
        [ -n "$speed" ] || continue
        log "  $ip ${speed} bytes/s"
        if [ "$speed" -gt "$best_speed" ]; then best_speed=$speed; best_ip=$ip; fi
    done

    [ -n "$best_ip" ] || { log "no reachable node, unchanged"; continue; }
    [ "$best_ip" != "$old_ip" ] || { log "best unchanged"; continue; }

    [ "$DRY_RUN" = 1 ] && { log "WOULD PIN: $domain -> $best_ip ($best_speed bytes/s)"; continue; }
    sed -i "/ $domain /d" "$HOSTS" || exit 1
    echo "$best_ip $domain $MARKER (${best_speed} bytes/s, $(date +%Y-%m-%d))" >> "$HOSTS"
    log "NEW: $domain -> $best_ip (${best_speed} bytes/s)"
    changed=1
done

if [ "$changed" = "1" ]; then
    /etc/init.d/dnsmasq reload 2>/dev/null || killall -HUP dnsmasq 2>/dev/null
    log "dnsmasq reloaded - LAN clients now get new IPs"
fi
log "done"
