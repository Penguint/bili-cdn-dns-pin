"""冷启 vs 预热对比：每个视频只打一次冷请求，再打一次热请求。"""
import json, time, statistics, collections, random
from lib import api, ts, pull, playurl

random.seed(7)
vids = []

# --- A: 近期热门（缓存必然是热的） ---
d = api("https://api.bilibili.com/x/web-interface/popular?ps=30&pn=1")
pop = [v for v in d["data"]["list"]]
for v in pop[6:14]:                                    # 跳过前6个（上一轮已被我摸过）
    vids.append({"g": "A-近期热门", "bvid": v["bvid"], "view": v["stat"]["view"], "pub": ts(v["pubdate"])})

# --- B/C: 老片 + 冷门，通过 related 图游走挖掘，全部是本轮首次触碰 ---
seeds = [v["bvid"] for v in pop[:12]]
found = {}
for s in seeds:
    try:
        for v in api(f"https://api.bilibili.com/x/web-interface/archive/related?bvid={s}")["data"]:
            p, view = ts(v["pubdate"]), v["stat"]["view"]
            if p >= "2026-06-01": continue
            g = None
            if view < 100_000:                     g = "D-冷门低播放"
            elif p < "2025-01-01":                 g = "C-陈年老片"
            elif p < "2026-06-01" and view < 600_000: g = "B-26上半年"
            if g: found.setdefault(v["bvid"], {"g": g, "bvid": v["bvid"], "view": view, "pub": p})
    except Exception as e:
        pass
    time.sleep(0.35)

by_g = collections.defaultdict(list)
for v in found.values(): by_g[v["g"]].append(v)
for g in ("B-26上半年", "C-陈年老片", "D-冷门低播放"):
    lst = sorted(by_g[g], key=lambda x: x["view"])
    random.shuffle(lst)
    vids += lst[:8]

print(f"候选 {len(vids)} 个视频，开始逐个测（每个：冷1次 + 热1次，各 8MiB）\n")
print(f'{"组":11} {"bvid":13} {"pub":11} {"view":>9} {"host":6} | {"冷TTFB":>7} {"冷Mbps":>8} | {"热TTFB":>7} {"热Mbps":>8} | cache')
print("-" * 132)

rows = []
for v in vids:
    try:
        pu = playurl(v["bvid"])
    except Exception as e:
        continue
    if not pu: continue
    host = "cosov" if "cosov" in pu["host"] else ("akam" if "akam" in pu["host"] else
           ("aliov" if "aliov" in pu["host"] else pu["host"][:12]))

    cold = pull(pu["url"], mb=8)                     # 首次触碰 = 冷
    if not cold or not cold["code"].startswith("2"): continue
    time.sleep(1.0)
    warm = pull(pu["url"], mb=8)                     # 立刻重打 = 热
    if not warm: warm = cold

    c = cold["cache"]
    ctag = (c.get("Cache") or c.get("EO-Cache-Status") or c.get("X-Cache-Lookup") or "")[:12]
    age = c.get("Age", "?")
    print(f'{v["g"]:11} {v["bvid"]:13} {v["pub"]:11} {v["view"]:>9,} {host:6} | '
          f'{cold["ttfb"]*1000:>6.0f}ms {cold["mbps"]:>7.1f} | '
          f'{warm["ttfb"]*1000:>6.0f}ms {warm["mbps"]:>7.1f} | {ctag} age={age}')
    rows.append({**v, "host": host, "bw": pu["bw"], "url": pu["url"], "backups": pu["backups"],
                 "cold_ttfb": cold["ttfb"], "cold_mbps": cold["mbps"], "cold_bytes": cold["bytes"],
                 "warm_ttfb": warm["ttfb"], "warm_mbps": warm["mbps"],
                 "ip": cold["ip"], "cache": c})
    time.sleep(0.8)

json.dump(rows, open("coldwarm.json", "w", encoding="utf-8"), ensure_ascii=False)

print("\n" + "=" * 60)
print(f'{"组":12} {"n":>3} {"冷TTFB中位":>11} {"冷吞吐中位":>11} {"热吞吐中位":>11}')
g = collections.defaultdict(list)
for r in rows: g[r["g"]].append(r)
for k in sorted(g):
    rs = g[k]
    print(f'{k:12} {len(rs):>3} {statistics.median([x["cold_ttfb"] for x in rs])*1000:>9.0f}ms '
          f'{statistics.median([x["cold_mbps"] for x in rs]):>10.1f} '
          f'{statistics.median([x["warm_mbps"] for x in rs]):>10.1f}')
print(f"\n保存 {len(rows)} 条 -> coldwarm.json")
