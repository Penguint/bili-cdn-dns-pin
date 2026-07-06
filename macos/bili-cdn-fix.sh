#!/bin/bash
# ============================================================
# bili-cdn-fix.sh (macOS)
# Test bilibili overseas CDN node IPs, pin the fastest into /etc/hosts.
# Usage:   sudo bash bili-cdn-fix.sh
# Undo:    sudo bash bili-cdn-fix.sh --restore
# ============================================================
set -u
MARKER="# BiliCdnFix"
HOSTS="/etc/hosts"
DOMAINS="upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo bash $0 $*"
    exit 1
fi

flush_dns() { dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; }

if [ "${1:-}" = "--restore" ]; then
    sed -i '' "/$MARKER/d" "$HOSTS"
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
    esac
}

resolve_extra() {
    { dig +short A "$1" @1.1.1.1 2>/dev/null; dig +short A "$1" @8.8.8.8 2>/dev/null; } \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

measure() { # TCP connect ms to :443, best of 2, empty = unreachable
    local ip="$1" best="" t ms i
    for i in 1 2; do
        t=$(curl -kso /dev/null -m 2 -w '%{time_connect}' "https://$ip/" 2>/dev/null)
        ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')
        [ "$ms" -gt 0 ] 2>/dev/null || continue
        if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
    done
    echo "$best"
}

cp "$HOSTS" "$HOSTS.bak_$(date +%Y%m%d_%H%M%S)"
NEW_LINES=""

for domain in $DOMAINS; do
    echo ""
    echo "Testing nodes for $domain ..."
    best_ip=""; best_ms=999999
    for ip in $(printf '%s\n%s\n' "$(candidates_for "$domain")" "$(resolve_extra "$domain")" | tr ' ' '\n' | sort -u); do
        [ -n "$ip" ] || continue
        ms=$(measure "$ip")
        [ -n "$ms" ] || continue
        printf "  %-16s %5s ms\n" "$ip" "$ms"
        if [ "$ms" -lt "$best_ms" ]; then best_ms=$ms; best_ip=$ip; fi
    done
    if [ -n "$best_ip" ]; then
        echo "  BEST: $best_ip  ${best_ms}ms"
        NEW_LINES="$NEW_LINES$best_ip $domain $MARKER (${best_ms}ms, $(date +%Y-%m-%d))\n"
    else
        echo "  No reachable node found, skipping."
    fi
done

if [ -z "$NEW_LINES" ]; then
    echo "Nothing to write."
    exit 1
fi

# remove old entries, append new
TMP=$(mktemp)
grep -v "$MARKER" "$HOSTS" | grep -vE "upos-hz-mirrorakam\.akamaized\.net|upos-sz-mirroraliov\.bilivideo\.com" > "$TMP"
printf "$NEW_LINES" >> "$TMP"
cat "$TMP" > "$HOSTS"
rm -f "$TMP"
flush_dns

echo ""
echo "Done! /etc/hosts updated (backup saved next to it)."
echo "Re-run anytime to re-test; --restore to undo."
