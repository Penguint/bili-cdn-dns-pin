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
HOSTS="/etc/hosts"
KEEP_THRESHOLD_MS=60
DOMAINS="upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

candidates_for() {
    case "$1" in
    upos-hz-mirrorakam.akamaized.net)
        echo "23.48.96.104 23.48.96.113 203.153.17.248 202.130.202.19 202.130.202.40 23.45.207.170 23.45.207.172 23.62.212.66 23.62.212.110 23.62.212.101 23.62.212.99 23.220.71.197 23.220.71.186 23.49.104.199 23.49.104.213 23.211.60.70 23.211.60.78 203.186.47.73 203.186.47.74 203.186.47.147 203.186.47.160" ;;
    upos-sz-mirroraliov.bilivideo.com)
        echo "163.181.81.231 163.181.81.233 163.181.81.236 163.181.35.183 163.181.35.184 155.102.4.5 155.102.4.6 155.102.4.141 155.102.4.145 163.181.78.183 163.181.78.184 47.246.38.202 47.246.38.203 47.246.41.174 47.246.41.175 47.246.41.176" ;;
    esac
}

resolve_extra() {
    nslookup "$1" 1.1.1.1 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^1\.1\.1\.1$' | sort -u
}

measure() {
    ip="$1"; best=""
    for i in 1 2; do
        t=$(curl -kso /dev/null -m 2 -w '%{time_connect}' "https://$ip/" 2>/dev/null)
        ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')
        [ "$ms" -gt 0 ] 2>/dev/null || continue
        if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
    done
    echo "$best"
}

changed=0
for domain in $DOMAINS; do
    log "=== $domain ==="
    old_ip=$(grep "$MARKER" "$HOSTS" | grep " $domain " | awk '{print $1}' | head -n1)

    if [ -n "$old_ip" ]; then
        old_ms=$(measure "$old_ip")
        if [ -n "$old_ms" ] && [ "$old_ms" -le "$KEEP_THRESHOLD_MS" ]; then
            log "current $old_ip still good (${old_ms}ms) - keeping"
            continue
        fi
        log "current $old_ip slow or dead (${old_ms:-timeout}) - re-testing"
    fi

    best_ip=""; best_ms=999999
    for ip in $(printf '%s\n%s\n' "$(candidates_for "$domain")" "$(resolve_extra "$domain")" | tr ' ' '\n' | sort -u); do
        [ -n "$ip" ] || continue
        ms=$(measure "$ip")
        [ -n "$ms" ] || continue
        log "  $ip ${ms}ms"
        if [ "$ms" -lt "$best_ms" ]; then best_ms=$ms; best_ip=$ip; fi
    done

    [ -n "$best_ip" ] || { log "no reachable node, unchanged"; continue; }
    [ "$best_ip" != "$old_ip" ] || { log "best unchanged"; continue; }

    sed -i "/ $domain /d" "$HOSTS"
    echo "$best_ip $domain $MARKER (${best_ms}ms, $(date +%Y-%m-%d))" >> "$HOSTS"
    log "NEW: $domain -> $best_ip (${best_ms}ms)"
    changed=1
done

if [ "$changed" = "1" ]; then
    /etc/init.d/dnsmasq reload 2>/dev/null || killall -HUP dnsmasq 2>/dev/null
    log "dnsmasq reloaded - LAN clients now get new IPs"
fi
log "done"
