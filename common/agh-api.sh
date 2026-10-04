# AdGuard API transport. GL.iNet mode is only for root on the router itself.
agh_request() (
    endpoint=$1; body=$2; shift 2
    if [ "${BILI_AGH_GLINET:-0}" = 1 ]; then
        [ "$(id -u)" = 0 ] || { echo "GL.iNet API mode requires router root" >&2; return 1; }
        case "$AGH_URL" in http://127.0.0.1:3000) ;; *) echo "GL.iNet API mode requires loopback URL" >&2; return 1 ;; esac
        umask 077
        token_file=$(mktemp /tmp/gl_token_XXXXXXXXXXXXXXXX) || return 1
        trap 'rm -f "$token_file"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' HUP TERM
        # GL.iNet stores native-endian uint32 creation time; its routers are little-endian.
        stamp=$(date +%s)
        for shift_bits in 0 8 16 24; do
            byte=$(( (stamp >> shift_bits) & 255 ))
            printf '%b' "$(printf '\\%03o' "$byte")"
        done > "$token_file"
        set -- "$@" --cookie "Admin-Token=${token_file#/tmp/gl_token_}"
    else
        set -- "$@" --user "$AGH_USER:$AGH_PASS"
    fi
    [ -z "$body" ] || set -- "$@" --header 'Content-Type: application/json' --data "$body"
    curl --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 20 \
        "$@" "$AGH_URL/control/$endpoint"
)
