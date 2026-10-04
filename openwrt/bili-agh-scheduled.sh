#!/bin/sh
# Run the existing AdGuard updater on a GL.iNet router, manually or from cron.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export BILI_AGH_URL=http://127.0.0.1:3000 BILI_AGH_GLINET=1
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# flock releases the lock even if the process is killed. It is supplied by BusyBox.
exec 9>/tmp/bili-cdn.lock
flock -n 9 || { echo "CDN task already running"; exit 0; }
[ ! -f /tmp/bili-cdn.log ] || mv /tmp/bili-cdn.log /tmp/bili-cdn.previous.log
sh "$SCRIPT_DIR/../server/bili-agh-update.sh" > /tmp/bili-cdn.log 2>&1
result=$?
logger -t bili-cdn "CDN task finished (exit $result); details: /tmp/bili-cdn.log"
exit "$result"
