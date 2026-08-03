"""回国加速器（穿梭等）有效性诊断。

用法：
    1) 先关闭加速器，跑一次：  python proxy_compare.py --tag off
    2) 打开加速器，再跑一次：  python proxy_compare.py --tag on
    3) 对比：                python proxy_compare.py --diff

回答三个问题：
    Q1 加速器有没有改变 B 站给你的 CDN 域名？（API 流量是否被代理）
    Q2 视频流本身走没走加速器？（媒体流量是否被代理，还是直连）
    Q3 冷启吞吐到底变好了没有？

注意：开加速器后拿到的是国内 CDN 的 URL —— 那是另一批边缘节点，
与之前测海外边缘时捂热的缓存互不影响，所以同一批视频可以复用。
"""
import json, sys, time, statistics, collections, urllib.parse, os
from lib import api, pull, playurl, ts

TAG = None
for i, a in enumerate(sys.argv):
    if a == "--tag" and i + 1 < len(sys.argv): TAG = sys.argv[i + 1]
DIFF = "--diff" in sys.argv


def egress():
    """当前出口 IP 与归属地 —— 判断加速器是否在代理普通 HTTP 流量。"""
    try:
        return api("https://ipinfo.io/json")
    except Exception as e:
        return {"error": str(e)}


def run(tag):
    info = egress()
    print(f'出口: {info.get("ip")} {info.get("city")} {info.get("country")} {info.get("org","")}')
    print()

    # 复用基线里那批视频，保证可比
    base = json.load(open("coldwarm.json", encoding="utf-8"))
    print(f'{"组":13} {"bvid":13} {"host":8} | {"冷TTFB":>8} {"冷Mbps":>8} | {"remote_ip":16} cache')
    print("-" * 110)

    rows = []
    for b in base:
        try:
            pu = playurl(b["bvid"])
        except Exception:
            continue
        if not pu: continue
        host = urllib.parse.urlparse(pu["url"]).hostname
        short = ("cosov" if "cosov" in host else "akam" if "akam" in host else
                 "aliov" if "aliov" in host else host.replace("upos-", "")[:14])
        r = pull(pu["url"], mb=8)
        if not r or not r["code"].startswith("2"):
            print(f'{b["g"]:13} {b["bvid"]:13} {short:8} | FAIL')
            continue
        c = r["cache"]
        ctag = (c.get("Cache") or c.get("EO-Cache-Status") or c.get("X-Cache-Lookup") or "-")[:10]
        print(f'{b["g"]:13} {b["bvid"]:13} {short:8} | {r["ttfb"]*1000:>6.0f}ms {r["mbps"]:>7.1f} | '
              f'{r["ip"]:16} {ctag} age={c.get("Age","?")}')
        rows.append({"g": b["g"], "bvid": b["bvid"], "host": host, "host_short": short,
                     "ttfb": r["ttfb"], "mbps": r["mbps"], "remote_ip": r["ip"],
                     "cache": ctag, "age": c.get("Age"),
                     "baseline_cold_mbps": b["cold_mbps"], "baseline_host": b["host"]})
        time.sleep(0.8)

    out = {"tag": tag, "egress": info, "rows": rows}
    json.dump(out, open(f"proxy_{tag}.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    # ---- Q1/Q2/Q3 ----
    print("\n" + "=" * 70)
    hosts = collections.Counter(r["host_short"] for r in rows)
    print(f'Q1 CDN 域名分布: {dict(hosts)}')
    changed = sum(1 for r in rows if r["host_short"] != r["baseline_host"])
    print(f'   相对基线改变的: {changed}/{len(rows)}'
          f'  → {"API 流量走了加速器" if changed > len(rows)*0.5 else "API 流量未被代理（或域名未变）"}')

    ips = collections.Counter(r["remote_ip"].rsplit(".", 2)[0] for r in rows)
    print(f'\nQ2 视频流 remote_ip 段: {dict(ips.most_common(5))}')
    print(f'   出口 IP = {info.get("ip")} ({info.get("country")})')
    print(f'   → 若 remote_ip 是国内段且出口也在国内，说明媒体流量走了隧道；'
          f'若出口在国内但 remote_ip 仍是海外段，说明媒体流量被分流直连')

    if rows:
        cur = statistics.median([r["mbps"] for r in rows])
        old = statistics.median([r["baseline_cold_mbps"] for r in rows])
        print(f'\nQ3 冷启吞吐中位: 基线 {old:.1f} → 本次 {cur:.1f} Mbps  ({cur/old if old else 0:.1f}x)')
        for name, need in (("1080P", 3.0), ("1080P高码率", 6.0), ("4K", 20.0)):
            a = sum(1 for r in rows if r["baseline_cold_mbps"] >= need)
            b2 = sum(1 for r in rows if r["mbps"] >= need)
            print(f'   {name:12} 需{need:>4.1f} Mbps  达标率 {a}/{len(rows)} → {b2}/{len(rows)}')
    print(f'\n保存 -> proxy_{tag}.json')


def diff():
    try:
        off = json.load(open("proxy_off.json", encoding="utf-8"))
        on = json.load(open("proxy_on.json", encoding="utf-8"))
    except FileNotFoundError as e:
        print("缺少数据文件，先分别用 --tag off / --tag on 各跑一次:", e); return
    m_off = {r["bvid"]: r for r in off["rows"]}
    print(f'出口  关: {off["egress"].get("ip")} {off["egress"].get("country")}   '
          f'开: {on["egress"].get("ip")} {on["egress"].get("country")}')
    print(f'\n{"bvid":13} {"组":13} {"关-host":8} {"开-host":8} {"关Mbps":>8} {"开Mbps":>8} {"倍数":>7}')
    print("-" * 78)
    ratios = []
    for r in on["rows"]:
        o = m_off.get(r["bvid"])
        if not o: continue
        ratio = r["mbps"] / o["mbps"] if o["mbps"] else 0
        ratios.append(ratio)
        print(f'{r["bvid"]:13} {r["g"]:13} {o["host_short"]:8} {r["host_short"]:8} '
              f'{o["mbps"]:>7.1f} {r["mbps"]:>7.1f} {ratio:>6.1f}x')
    if ratios:
        print(f'\n提升倍数: 中位 {statistics.median(ratios):.2f}x  '
              f'最好 {max(ratios):.1f}x  最差 {min(ratios):.2f}x')
        worse = sum(1 for x in ratios if x < 1)
        print(f'反而变慢的: {worse}/{len(ratios)}')
        print('\n→ 若中位提升接近 1x 但方差极大，即用户描述的"有时有用有时没用"，'
              '说明加速器只在部分内容/时段生效')


if __name__ == "__main__":
    if DIFF: diff()
    elif TAG: run(TAG)
    else: print(__doc__)
