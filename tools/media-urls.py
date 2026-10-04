#!/usr/bin/env python3
"""Fetch fresh highest-available video AND audio URLs; no login/cookies stored."""
import argparse
import os
import re
from pathlib import Path
import sys
from urllib.parse import urlparse
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'research'))
from lib import api


def get_cid(bvid):
    try:
        info = api('https://api.bilibili.com/x/web-interface/view?bvid=' + bvid)
        if info.get('code') == 0:
            return info['data']['cid']
    except Exception:
        pass
    # The view endpoint can return HTTP 412 even for public videos.
    pages = api('https://api.bilibili.com/x/player/pagelist?bvid=' + bvid)
    if pages.get('code') != 0 or not pages.get('data'):
        raise SystemExit('Cannot obtain content ID; try --cid with the player content ID')
    return pages['data'][0]['cid']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bvid')
    parser.add_argument('--video-codec', choices=('auto', 'hevc', 'avc', 'av1'), default='auto',
                        help='Select the highest-bandwidth rendition within this codec (default: auto)')
    parser.add_argument('--cid', type=int, help='Known content ID; skip the view API')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'media')
    args = parser.parse_args()
    if not re.fullmatch(r'BV[0-9A-Za-z]{10}', args.bvid):
        parser.error('Expected a BVID such as BV1Ra4y117kf')
    cid = args.cid if args.cid is not None else get_cid(args.bvid)
    result = api(f'https://api.bilibili.com/x/player/playurl?bvid={args.bvid}&cid={cid}&qn=127&fnval=4048&fourk=1')
    dash = result.get('data', {}).get('dash')
    if result.get('code') != 0 or not dash or not dash.get('video') or not dash.get('audio'):
        raise SystemExit('No video/audio DASH URLs available')
    if args.video_codec != 'auto':
        codec_id = {'avc': 7, 'hevc': 12, 'av1': 13}[args.video_codec]
        dash['video'] = [r for r in dash['video'] if r.get('codecid') == codec_id]
        if not dash['video']:
            raise SystemExit('Requested video codec is not available; try --video-codec auto')
    records = {kind: max(dash[kind], key=lambda r: r.get('bandwidth', 0)) for kind in ('video', 'audio')}
    # Fetch both before changing files. URLs carry expiring signatures; never commit them.
    args.output.mkdir(parents=True, exist_ok=True)
    def save(name, url):
        path = args.output / (name + '.url')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(url + '\n')
        os.chmod(path, 0o600)
        return path
    hosts = ('upos-hz-mirrorakam.akamaized.net', 'upos-sz-mirroraliov.bilivideo.com', 'upos-sz-mirrorcosov.bilivideo.com')
    for kind, record in records.items():
        path = save(kind, record['baseUrl'])
        for host in hosts:
            domain_path = args.output / (host + '.' + kind + '.url')
            domain_path.unlink(missing_ok=True)
            for candidate in sorted(dash[kind], key=lambda r: r.get('bandwidth', 0), reverse=True):
                urls = [candidate['baseUrl']] + (candidate.get('backupUrl') or [])
                match = next((u for u in urls if urlparse(u).scheme == 'https' and urlparse(u).hostname == host), None)
                if match:
                    save(host + '.' + kind, match)
                    break
        print(f'{kind}: rendition={record["id"]} bandwidth={record.get("bandwidth", 0)} codec={record.get("codecs", "unknown")} saved to {path}')
    print('URLs expire: refresh before each scheduled run. Without login the API may cap video quality.')

if __name__ == '__main__':
    main()
