# Native media discovery for the shell entry points (curl + jq).
media_api() {
    curl --fail --silent --show-error --proto '=https' --connect-timeout 5 \
        --max-time 25 --retry 2 --user-agent 'Mozilla/5.0' \
        --referer 'https://www.bilibili.com/' "$1"
}

prepare_media() {
    command -v jq >/dev/null 2>&1 || { echo "Install jq before running this entry point" >&2; return 1; }
    bvid=${BILI_BVID:-BV1Ra4y117kf}
    printf '%s\n' "$bvid" | grep -Eq '^BV[0-9A-Za-z]{10}$' || { echo "Invalid BILI_BVID" >&2; return 1; }
    case "${BILI_VIDEO_CODEC:-hevc}" in
        auto) codec=0 ;; hevc) codec=12 ;; avc) codec=7 ;; av1) codec=13 ;;
        *) echo "Invalid BILI_VIDEO_CODEC" >&2; return 1 ;;
    esac
    cid=${BILI_CID:-}
    if [ -z "$cid" ]; then
        cid=$(media_api "https://api.bilibili.com/x/web-interface/view?bvid=$bvid" 2>/dev/null |
            jq -er 'select(.code == 0) | .data.cid // empty' 2>/dev/null) || cid=''
        if [ -z "$cid" ]; then
            cid=$(media_api "https://api.bilibili.com/x/player/pagelist?bvid=$bvid" |
                jq -er 'select(.code == 0) | .data[0].cid // empty') || return 1
        fi
    fi
    case "$cid" in ''|*[!0-9]*) echo "Cannot obtain content ID" >&2; return 1 ;; esac
    media_tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$media_tmp"' EXIT
    BILI_MEDIA_DIR=$media_tmp
    media_api "https://api.bilibili.com/x/player/playurl?bvid=$bvid&cid=$cid&qn=127&fnval=4048&fourk=1" > "$media_tmp/play.json" || return 1
    jq -e --argjson codec "$codec" '
        select(.code == 0) | .data.dash |
        .video |= map(select($codec == 0 or .codecid == $codec)) |
        select((.video | length) > 0 and (.audio | length) > 0)
    ' "$media_tmp/play.json" > "$media_tmp/dash.json" || { echo "No video/audio for requested codec" >&2; return 1; }
    for kind in video audio; do
        jq -er --arg kind "$kind" '.[$kind] | max_by(.bandwidth // 0) | .baseUrl // .base_url' "$media_tmp/dash.json" > "$media_tmp/$kind.url" || return 1
        for host in upos-hz-mirrorakam.akamaized.net upos-sz-mirroraliov.bilivideo.com upos-sz-mirrorcosov.bilivideo.com; do
            jq -r --arg kind "$kind" --arg host "$host" '
                [.[$kind] | sort_by(.bandwidth // 0) | reverse | .[] |
                ((.baseUrl // .base_url), ((.backupUrl // .backup_url // [])[])) |
                select(type == "string" and startswith("https://" + $host + "/"))][0] // empty
            ' "$media_tmp/dash.json" > "$media_tmp/$host.$kind.url" || return 1
            [ -s "$media_tmp/$host.$kind.url" ] || rm -f "$media_tmp/$host.$kind.url"
        done
        chmod 600 "$media_tmp"/*.url
    done
    echo "Fresh video/audio fetched: $bvid (${BILI_VIDEO_CODEC:-hevc})" >&2
}
