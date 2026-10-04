# Shared by the existing macOS, OpenWrt and AdGuard entry points.
SPEED_ROUNDS=${BILI_SPEED_ROUNDS:-3}
SPEED_BYTES=${BILI_SPEED_BYTES:-33554432}
SPEED_TIMEOUT=${BILI_SPEED_TIMEOUT:-60}
KEEP_THRESHOLD_BPS=${BILI_KEEP_BPS:-5000000}
DRY_RUN=${BILI_DRY_RUN:-0}

speed_init() {
    case "$SPEED_ROUNDS:$SPEED_BYTES:$SPEED_TIMEOUT:$KEEP_THRESHOLD_BPS" in
        *[!0-9:]*|:*|*::*|*:) echo "Invalid speed settings" >&2; return 1 ;;
    esac
    [ "$SPEED_ROUNDS" -ge 3 ] && [ "$SPEED_BYTES" -gt 0 ] && [ "$SPEED_TIMEOUT" -gt 0 ] || return 1
    # Explicit URLs or a caller-managed directory remain available for custom tests.
    if [ -z "${BILI_VIDEO_URL:-}" ] || [ -z "${BILI_AUDIO_URL:-}" ]; then
        if [ "${BILI_USE_MEDIA_FILES:-0}" != 1 ]; then
            . "$SCRIPT_DIR/../common/media-urls.sh"
            prepare_media || return 1
        fi
    fi
    VIDEO_URL_EXPLICIT=${BILI_VIDEO_URL:+1}
    AUDIO_URL_EXPLICIT=${BILI_AUDIO_URL:+1}
    BILI_VIDEO_URL=${BILI_VIDEO_URL:-$(cat "$BILI_MEDIA_DIR/video.url" 2>/dev/null)}
    BILI_AUDIO_URL=${BILI_AUDIO_URL:-$(cat "$BILI_MEDIA_DIR/audio.url" 2>/dev/null)}
    for media_url in "$BILI_VIDEO_URL" "$BILI_AUDIO_URL"; do
        case "$media_url" in
            https://upos-hz-mirrorakam.akamaized.net/*|https://upos-sz-mirroraliov.bilivideo.com/*|https://upos-sz-mirrorcosov.bilivideo.com/*) ;;
            *) echo "Cannot obtain valid video/audio URLs" >&2; return 1 ;;
        esac
    done
}

# Returns integer bytes/s: the lower of video and audio medians.
# Require every round to succeed; preserve TLS hostname/SNI with --resolve.
measure() (
    domain=$1; ip=$2
    case "$ip" in *[!0-9.]*|0.0.0.0|'') return 1 ;; esac
    scratch=$(mktemp -d) || return 1
    trap 'rm -rf "$scratch"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    score=''
    for kind in video audio; do
        if [ "$kind" = video ]; then source_url=$BILI_VIDEO_URL; else source_url=$BILI_AUDIO_URL; fi
        if [ "$kind" = video ]; then explicit=$VIDEO_URL_EXPLICIT; else explicit=$AUDIO_URL_EXPLICIT; fi
        if [ -z "$explicit" ] && [ -f "$BILI_MEDIA_DIR/$domain.$kind.url" ]; then
            source_url=$(cat "$BILI_MEDIA_DIR/$domain.$kind.url")
        fi
        case "$source_url" in https://upos-hz-mirrorakam.akamaized.net/*|https://upos-sz-mirroraliov.bilivideo.com/*|https://upos-sz-mirrorcosov.bilivideo.com/*) ;; *) return 1 ;; esac
        path=${source_url#https://}; path=${path#*/}
        url="https://$domain/$path"
        : > "$scratch/speeds"
        round=1
        while [ "$round" -le "$SPEED_ROUNDS" ]; do
            stats=$(curl --silent --show-error --noproxy '*' --proto '=https' \
                --connect-timeout 5 --max-time "$SPEED_TIMEOUT" \
                --max-filesize "$SPEED_BYTES" --range "0-$((SPEED_BYTES - 1))" \
                --user-agent 'Mozilla/5.0' --referer 'https://www.bilibili.com/' \
                --resolve "$domain:443:$ip" --dump-header "$scratch/headers" \
                --output /dev/null --write-out '%{http_code} %{size_download} %{speed_download}' \
                "$url" 2> "$scratch/error")
            result=$?
            if [ "$result" -ne 0 ]; then
                echo "  $domain $ip $kind round=$round failed (curl $result)" >&2
                return 1
            fi
            # A byte range must start at 0 and cover min(requested, total).
            # Reject redirects, HTML errors, ignored ranges and partial bodies.
            speed=$(awk -v stats="$stats" -v limit="$SPEED_BYTES" '
                tolower($1)=="content-range:" && tolower($2)=="bytes" {
                    gsub("\r", "", $3); split($3, v, /[-\/]/); start=v[1]; end=v[2]; total=v[3]; found=1
                }
                END {
                    split(stats, s, " "); expected=(total<limit ? total : limit)
                    if (s[1]==206 && found && total ~ /^[0-9]+$/ && start==0 && expected>0 &&
                        end==expected-1 && s[2]==expected && s[3]>0) printf "%.0f", s[3]
                }' "$scratch/headers")
            [ -n "$speed" ] || { echo "  $domain $ip $kind round=$round invalid range/HTTP response" >&2; return 1; }
            echo "$speed" >> "$scratch/speeds"
            echo "  $domain $ip $kind round=$round $stats (HTTP bytes bytes/s)" >&2
            round=$((round + 1))
        done
        median=$(sort -n "$scratch/speeds" | awk '{v[NR]=$1} END {if(NR%2) print v[(NR+1)/2]; else printf "%.0f",(v[NR/2]+v[NR/2+1])/2}')
        if [ -z "$score" ] || [ "$median" -lt "$score" ]; then score=$median; fi
    done
    echo "$score"
)

# DoH discovery avoids measuring only an existing pin or intercepted public DNS.
resolve_extra() {
    curl --silent --show-error --max-time 15 --header 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
        | grep -o '"data"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*:[[:space:]]*"//; s/"$//' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | grep -vE '^(0\.|127\.)' | sort -u
}
