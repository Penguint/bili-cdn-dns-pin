import json, urllib.request, urllib.parse, time, datetime, collections

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36",
      "Referer": "https://www.bilibili.com/"}

def get(url, tries=3):
    for i in range(tries):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=25))
        except Exception as e:
            if i == tries - 1: raise
            time.sleep(1.5)

def ts(t): return datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d")

vids = []

# --- Group A: recent popular ---
d = get("https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1")
for v in d["data"]["list"]:
    vids.append({"g": "A-近期热门", "bvid": v["bvid"], "view": v["stat"]["view"], "pub": ts(v["pubdate"])})
    if sum(1 for x in vids if x["g"] == "A-近期热门") >= 6: break

# --- Group B: 2026 H1 weekly-must-see, moderate view counts ---
cand = []
for num in (352, 356, 360, 364, 368):     # roughly Jan-Apr 2026
    try:
        d = get(f"https://api.bilibili.com/x/web-interface/popular/series/one?number={num}")
        for v in d["data"]["list"]:
            cand.append({"g": "B-26上半年", "bvid": v["bvid"], "view": v["stat"]["view"], "pub": ts(v["pubdate"])})
    except Exception as e:
        print("series", num, "failed:", e)
    time.sleep(0.5)
# prefer the 10万-50万 band the user described
band = sorted([c for c in cand if 100_000 <= c["view"] <= 500_000], key=lambda x: x["pub"])
vids += band[:7]

# --- Group C: genuinely old, via related-graph walk ---
seen_c = {}
for seed in [v["bvid"] for v in vids[:3]]:
    try:
        d = get(f"https://api.bilibili.com/x/web-interface/archive/related?bvid={seed}")
        for v in d["data"]:
            p = ts(v["pubdate"])
            if p < "2025-06-01" and v["stat"]["view"] < 800_000:
                seen_c[v["bvid"]] = {"g": "C-陈年老片", "bvid": v["bvid"],
                                     "view": v["stat"]["view"], "pub": p}
    except Exception as e:
        print("related", seed, "failed:", e)
    time.sleep(0.5)
vids += sorted(seen_c.values(), key=lambda x: x["pub"])[:6]

# --- resolve playurl for each ---
res = []
hostcount = collections.Counter()
for v in vids:
    try:
        info = get(f'https://api.bilibili.com/x/web-interface/view?bvid={v["bvid"]}')
        cid = info["data"]["cid"]
        dur = info["data"]["duration"]
        p = get(f'https://api.bilibili.com/x/player/playurl?bvid={v["bvid"]}&cid={cid}&qn=127&fnval=4048&fourk=1')
        dash = p["data"].get("dash")
        if not dash:
            print("no dash", v["bvid"]); continue
        best = max(dash["video"], key=lambda x: x.get("bandwidth", 0))
        host = urllib.parse.urlparse(best["baseUrl"]).hostname
        backups = [u for u in (best.get("backupUrl") or [])]
        hostcount[host] += 1
        for b in backups: hostcount["(backup) " + urllib.parse.urlparse(b).hostname] += 1
        res.append({**v, "cid": cid, "dur": dur, "qid": best["id"],
                    "bw": best.get("bandwidth", 0), "host": host,
                    "url": best["baseUrl"], "backups": backups})
        print(f'{v["g"]:10} {v["bvid"]:14} {v["pub"]} view={v["view"]:>9,} q={best["id"]:3} bw={best.get("bandwidth",0)//1000:>5}k host={host}')
    except Exception as e:
        print("playurl failed", v["bvid"], e)
    time.sleep(0.6)

print("\n=== host distribution ===")
for h, c in hostcount.most_common(): print(f"{c:3}  {h}")

json.dump(res, open("videos.json", "w", encoding="utf-8"), ensure_ascii=False)
print("\nsaved", len(res), "videos -> videos.json")
