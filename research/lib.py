import json, subprocess, re, os, time, urllib.request, urllib.parse, datetime

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
HDRS = {"User-Agent": UA, "Referer": "https://www.bilibili.com/"}
DEVNULL = os.devnull                      # 'nul' on Windows -- MSYS does NOT translate for direct exec
FMT = "%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download} %{remote_ip}"

def api(url, tries=3):
    for i in range(tries):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=HDRS), timeout=25))
        except Exception:
            if i == tries - 1: raise
            time.sleep(1.5)

def ts(t): return datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d")

CACHE_KEYS = ("x-cache", "cache:", "age:", "eo-cache-status", "x-cached-since", "x-id", "x-server")

def pull(url, resolve=None, mb=8, timeout=35, headers=True):
    """Download first `mb` MiB. Returns dict incl. throughput and CDN cache headers."""
    cmd = ["curl", "-s", "-o", DEVNULL, "-w", "\nSTATS " + FMT + "\n",
           "-H", f"User-Agent: {UA}", "-H", "Referer: https://www.bilibili.com/",
           "-H", f"Range: bytes=0-{mb*1024*1024-1}", "--max-time", str(timeout), url]
    if headers: cmd[4:4] = ["-D", "-"]
    if resolve: cmd[1:1] = ["--resolve", resolve]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, errors="replace",
                             timeout=timeout + 15).stdout
    except subprocess.TimeoutExpired:
        return None
    m = re.search(r"STATS (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S*)", out)
    if not m: return None
    code, tc, ta, tt, tot, size, spd, rip = m.groups()
    cache = {}
    for line in out.splitlines():
        low = line.lower()
        for k in CACHE_KEYS:
            if low.startswith(k):
                kk, _, vv = line.partition(":")
                cache[kk.strip()] = vv.strip()
    return {"code": code, "connect": float(tc), "tls": float(ta), "ttfb": float(tt),
            "total": float(tot), "bytes": int(size), "mbps": float(spd) * 8 / 1e6,
            "ip": rip, "cache": cache}

def playurl(bvid):
    info = api(f"https://api.bilibili.com/x/web-interface/view?bvid={bvid}")
    cid = info["data"]["cid"]
    p = api(f"https://api.bilibili.com/x/player/playurl?bvid={bvid}&cid={cid}&qn=127&fnval=4048&fourk=1")
    dash = p["data"].get("dash")
    if not dash: return None
    best = max(dash["video"], key=lambda x: x.get("bandwidth", 0))
    return {"cid": cid, "qid": best["id"], "bw": best.get("bandwidth", 0),
            "url": best["baseUrl"], "backups": best.get("backupUrl") or [],
            "host": urllib.parse.urlparse(best["baseUrl"]).hostname}
