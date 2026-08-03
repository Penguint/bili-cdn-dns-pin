"""实验2：项目"钉住最低延迟IP"的方法学检验。
在一个必然全网缓存命中的热门文件上，逐个种子IP实测 TCP延迟 与 真实吞吐，
看延迟能不能预测吞吐（项目的核心假设），以及最优IP相对默认DNS有无增益。"""
import json, re, statistics, sys, time, urllib.parse, subprocess
from concurrent.futures import ThreadPoolExecutor
from lib import pull, playurl, api, ts

PS1 = r"C:\Users\lzz28\VSCode Project\bili-cdn-dns-pin\windows\bili-cdn-fix.ps1"
src = open(PS1, encoding="utf-8", errors="replace").read()

def seeds_for(domain):
    m = re.search(re.escape('"' + domain + '"') + r'\s*=\s*@\((.*?)\)', src, re.S)
    return re.findall(r'\d+\.\d+\.\d+\.\d+', m.group(1)) if m else []

AKAM = "upos-hz-mirrorakam.akamaized.net"
ALIOV = "upos-sz-mirroraliov.bilivideo.com"
akam_ips, aliov_ips = seeds_for(AKAM), seeds_for(ALIOV)
print(f"种子IP：akam={len(akam_ips)}  aliov={len(aliov_ips)}")

# 找一个 akam 承载的热门视频（缓存必热）
d = api("https://api.bilibili.com/x/web-interface/popular?ps=40&pn=1")
target = None
for v in d["data"]["list"]:
    try: pu = playurl(v["bvid"])
    except Exception: continue
    if not pu: continue
    url = pu["url"] if AKAM in pu["host"] else next((b for b in pu["backups"] if AKAM in b), None)
    if url:
        target = {"bvid": v["bvid"], "view": v["stat"]["view"], "pub": ts(v["pubdate"]), "url": url}
        break
    time.sleep(0.3)

if not target:
    print("没找到 akam 上的热门视频"); sys.exit(1)
print(f'测试载体：{target["bvid"]} {target["pub"]} view={target["view"]:,}（热门=缓存命中）\n')

# 先预热一遍默认节点
pull(target["url"], mb=4)

def probe(ip):
    r = pull(target["url"], resolve=f"{AKAM}:443:{ip}", mb=8, timeout=25)
    return ip, r

print(f'{"IP":18} {"TCP":>7} {"TLS":>7} {"TTFB":>7} {"MB":>6} {"Mbps":>8}  {"cache":>10}')
print("-" * 78)
results = []
with ThreadPoolExecutor(max_workers=1) as ex:      # 串行，避免互相抢带宽
    for ip, r in ex.map(probe, akam_ips):
        if not r or not r["code"].startswith("2"):
            print(f'{ip:18} {"":>7} {"":>7} {"":>7} {"":>6} {"FAIL/" + (r["code"] if r else "timeout"):>8}')
            results.append({"ip": ip, "ok": False}); continue
        c = r["cache"]
        ctag = (c.get("Cache") or c.get("EO-Cache-Status") or c.get("X-Cache-Lookup") or "-")[:10]
        print(f'{ip:18} {r["connect"]*1000:>6.0f}ms {r["tls"]*1000:>6.0f}ms {r["ttfb"]*1000:>6.0f}ms '
              f'{r["bytes"]/1e6:>5.1f}M {r["mbps"]:>7.1f}  {ctag:>10}')
        results.append({"ip": ip, "ok": True, "connect": r["connect"], "ttfb": r["ttfb"],
                        "mbps": r["mbps"], "bytes": r["bytes"], "cache": ctag})

# 默认DNS基线
base = [pull(target["url"], mb=8) for _ in range(3)]
base = [b for b in base if b and b["code"].startswith("2")]
json.dump({"target": target, "results": results,
           "baseline": [{"ip": b["ip"], "connect": b["connect"], "mbps": b["mbps"]} for b in base]},
          open("pin_test.json", "w", encoding="utf-8"), ensure_ascii=False)

ok = [r for r in results if r["ok"] and r["bytes"] > 4e6]
print("\n" + "=" * 78)
if base:
    print(f'默认DNS基线：ip={base[0]["ip"]} 延迟={base[0]["connect"]*1000:.0f}ms '
          f'吞吐中位={statistics.median([b["mbps"] for b in base]):.1f} Mbps')
print(f'种子IP：{len(results)} 个中 {len(ok)} 个可用（{len(results)-len(ok)} 个已失效）')
if len(ok) >= 3:
    lat_best = min(ok, key=lambda x: x["connect"])
    thr_best = max(ok, key=lambda x: x["mbps"])
    print(f'延迟最低的IP  ：{lat_best["ip"]:16} {lat_best["connect"]*1000:5.0f}ms → 实测 {lat_best["mbps"]:6.1f} Mbps  ← 项目会钉这个')
    print(f'吞吐最高的IP  ：{thr_best["ip"]:16} {thr_best["connect"]*1000:5.0f}ms → 实测 {thr_best["mbps"]:6.1f} Mbps  ← 实际最优')
    # 相关性
    xs = [r["connect"] for r in ok]; ys = [r["mbps"] for r in ok]
    n = len(xs); mx, my = statistics.mean(xs), statistics.mean(ys)
    cov = sum((a-mx)*(b-my) for a, b in zip(xs, ys))
    den = (sum((a-mx)**2 for a in xs) * sum((b-my)**2 for b in ys)) ** 0.5
    print(f'\n延迟 vs 吞吐 皮尔逊相关系数 r = {cov/den if den else 0:+.3f}   (越接近 -1 说明"低延迟=高吞吐"越成立)')
