#!/bin/bash
# ============================================================
# bili-agh-update.sh
# Generic always-on server (Synology / macOS / Debian):
# test bilibili overseas CDN nodes, pin the fastest IP into
# AdGuard Home DNS rewrites. Run weekly via cron/Task Scheduler.
# Stability rule: keep current IP unless media downloads fail or drop below the throughput threshold.
# ============================================================

# ------- EDIT THESE 3 LINES -------
AGH_URL="http://127.0.0.1:80"      # AdGuard Home admin address (port chosen during setup, often 80 or 3000)
AGH_USER="admin"                   # AdGuard Home login
AGH_PASS="CHANGE_ME"               # AdGuard Home password
# ----------------------------------

KEEP_THRESHOLD_BPS=${BILI_KEEP_BPS:-5000000}               # keep current node if both media medians reach this bytes/s threshold
ROUTER_DNS=""                      # optional: router IP whose static DNS entries must stay in sync (empty = skip check)
STATE_FILE="$(cd "$(dirname "$0")" && pwd)/bili-agh-state.txt"
DOMAINS=${BILI_DOMAINS:-"upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com upos-sz-mirrorcosov.bilivideo.com"}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

candidates_for() {
    case "$1" in
    upos-hz-mirrorakam.akamaized.net)
        echo "23.48.96.104 23.48.96.113 203.153.17.248 202.130.202.19 202.130.202.40 23.45.207.170 23.45.207.172 23.62.212.66 23.62.212.110 23.62.212.101 23.62.212.99 23.62.212.96 23.220.71.197 23.220.71.186 23.49.104.199 23.49.104.213 23.211.60.70 23.211.60.78 203.186.47.73 203.186.47.74 203.186.47.147 203.186.47.160 203.186.47.162" ;;
    upos-sz-mirroraliov.bilivideo.com)
        echo "47.246.41.174 47.246.41.175 47.246.41.176 47.246.41.177 47.246.41.178 47.246.41.179 47.246.41.180 47.246.41.181 163.181.81.231 163.181.81.233 163.181.81.236 163.181.35.183 163.181.35.184 163.181.35.180 155.102.4.5 155.102.4.6 155.102.4.141 155.102.4.145 163.181.78.183 163.181.78.184" ;;
    upos-sz-mirrorcosov.bilivideo.com) echo "${BILI_COSOV_IPS:-}" ;;
    esac
}

# Median real download throughput; require video and audio to pass.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BILI_MEDIA_DIR=${BILI_MEDIA_DIR:-"$SCRIPT_DIR/../media"}
. "$SCRIPT_DIR/../common/download-speed.sh"
speed_init || exit 1

agh() { # agh <endpoint> <domain> <ip>
    curl -s -o /dev/null -w '%{http_code}' -u "$AGH_USER:$AGH_PASS" \
        -H 'Content-Type: application/json' \
        -d "{\"domain\":\"$2\",\"answer\":\"$3\"}" \
        "$AGH_URL/control/rewrite/$1"
}

[ "$DRY_RUN" = 1 ] || touch "$STATE_FILE" || exit 1

for domain in $DOMAINS; do
    log "=== $domain ==="
    old_ip=$(grep "^$domain=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)

    # if current pinned node is still healthy, do nothing
    if [ -n "$old_ip" ]; then
        old_speed=$(measure "$domain" "$old_ip")
        if [ -n "$old_speed" ] && [ "$old_speed" -ge "$KEEP_THRESHOLD_BPS" ]; then
            log "current $old_ip still good (${old_speed} bytes/s) - keeping"
            continue
        fi
        log "current $old_ip is slow or dead (${old_speed:-failed} bytes/s) - re-testing"
    fi

    # test all candidates
    best_ip=""; best_speed=0
    for ip in $(printf '%s\n%s\n' "${BILI_CANDIDATE_IPS:-$(candidates_for "$domain")}" "$(resolve_extra "$domain")" | tr ' ' '\n' | sort -u); do
        [ -n "$ip" ] || continue
        speed=$(measure "$domain" "$ip")
        [ -n "$speed" ] || continue
        log "  $ip ${speed} bytes/s"
        if [ "$speed" -gt "$best_speed" ]; then best_speed=$speed; best_ip=$ip; fi
    done

    if [ -z "$best_ip" ]; then
        log "no reachable node found, leaving rewrite unchanged"
        continue
    fi
    if [ "$best_ip" = "$old_ip" ]; then
        log "best is still $best_ip (${best_speed} bytes/s) - no change"
        continue
    fi

    [ "$DRY_RUN" = 1 ] && { log "WOULD PIN: $domain -> $best_ip ($best_speed bytes/s)"; continue; }

    # update AdGuard Home rewrite
    if [ -n "$old_ip" ]; then
        code=$(agh delete "$domain" "$old_ip")
        log "deleted old rewrite $old_ip (HTTP $code)"
        [ "$code" = "200" ] || { log "delete failed, leaving state unchanged"; continue; }
    fi
    code=$(agh add "$domain" "$best_ip")
    if [ "$code" = "200" ]; then
        log "NEW rewrite: $domain -> $best_ip (${best_speed} bytes/s)"
        grep -v "^$domain=" "$STATE_FILE" > "$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"
        echo "$domain=$best_ip" >> "$STATE_FILE"
    else
        log "FAILED to add rewrite (HTTP $code) - check AGH_URL/USER/PASS"
        [ -z "$old_ip" ] || agh add "$domain" "$old_ip" >/dev/null
    fi
done

# --- check router static DNS entries are still in sync (optional) ---
if [ "$DRY_RUN" != 1 ] && [ -n "$ROUTER_DNS" ]; then
    MISMATCH=""
    for domain in $DOMAINS; do
        pinned=$(grep "^$domain=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
        [ -n "$pinned" ] || continue
        answers=$(nslookup "$domain" "$ROUTER_DNS" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "^$ROUTER_DNS\$")
        if [ -z "$answers" ]; then
            MISMATCH="$MISMATCH  $domain: router DNS gave no answer (router down or entry missing)\n"
        elif ! echo "$answers" | grep -q "^$pinned\$"; then
            MISMATCH="$MISMATCH  $domain: router answers [$(echo $answers | tr '\n' ' ')], should be $pinned\n"
        fi
    done
    if [ -n "$MISMATCH" ]; then
        log "WARNING: router static DNS is OUT OF SYNC - update it manually:"
        printf "$MISMATCH"
        command -v synodsmnotify >/dev/null 2>&1 && \
            synodsmnotify @administrators "bili-cdn-pin" "Router static DNS entries need updating - see task log" 2>/dev/null
        log "exiting with error so DSM Task Scheduler can email you"
        exit 1
    fi
    log "router static DNS in sync"
fi
log "done"
