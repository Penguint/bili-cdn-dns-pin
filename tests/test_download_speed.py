"""Exercise real shell scoring with a deterministic curl substitute."""
import os
import importlib.util
import sys
from unittest.mock import patch
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
a=sys.argv[1:]
if '--dump-header' not in a:
 print('{"Answer":[]}'); sys.exit(0)
def value(flag): return a[a.index(flag)+1]
assert '-k' not in a and '--insecure' not in a
assert '--resolve' in a and '--noproxy' in a
if os.environ.get('EXPECTED_TOKEN'): assert os.environ['EXPECTED_TOKEN'] in a[-1]
kind='video' if '/video?' in a[-1] else 'audio'
ip=value('--resolve').split(':')[-1]
state=Path(os.environ['MOCK_STATE'])
data=json.loads(state.read_text()) if state.exists() else {}
key=ip+kind; n=data.get(key,0); data[key]=n+1; state.write_text(json.dumps(data))
mode=os.environ.get('MOCK_MODE','ok')
if mode=='tls': sys.exit(60)
if mode=='timeout' and n==1: sys.exit(28)
total=50 if mode=='small' else 1000
limit=int(value('--max-filesize')); count=min(total,limit)
status=200 if mode=='ignored' else 206
end=count-2 if mode=='range' else count-1
Path(value('--dump-header')).write_text(f'HTTP/2 {status}\r\nContent-Range: bytes 0-{end}/{total}\r\n')
speed=([900,100,500] if kind=='video' else [300,700,600])[n%3]
if ip.endswith('.2'): speed=200
print(status, count-1 if mode=='partial' else count, speed)
'''

class DownloadSpeed(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p=Path(self.tmp.name)
        curl=p/'curl'; curl.write_text(MOCK); curl.chmod(0o755)
        self.env=dict(os.environ, PATH=str(p)+':'+os.environ['PATH'], MOCK_STATE=str(p/'state'),
                      BILI_VIDEO_URL='https://upos-hz-mirrorakam.akamaized.net/video?token=test',
                      BILI_AUDIO_URL='https://upos-hz-mirrorakam.akamaized.net/audio?token=test',
                      BILI_SPEED_BYTES='100', BILI_SPEED_ROUNDS='3', BILI_DRY_RUN='1')
    def measure(self, mode='ok', rounds='3'):
        self.env.update(MOCK_MODE=mode, BILI_SPEED_ROUNDS=rounds)
        return subprocess.run(['sh','-c','. "$1"; speed_init || exit; measure upos-hz-mirrorakam.akamaized.net 1.2.3.1','sh',str(ROOT/'common/download-speed.sh')],env=self.env,text=True,capture_output=True)
    def test_both_medians_and_lower_score(self):
        r=self.measure(); self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(r.stdout.strip(),'500')
        self.assertEqual(r.stderr.count('round='),6)
    def test_domain_signed_urls_preferred(self):
        p=Path(self.tmp.name)
        for kind in ('video','audio'):
            (p/(kind+'.url')).write_text('https://upos-sz-mirrorcosov.bilivideo.com/'+kind+'?generic')
            (p/('upos-hz-mirrorakam.akamaized.net.'+kind+'.url')).write_text('https://upos-hz-mirrorakam.akamaized.net/'+kind+'?original-signature')
        self.env.pop('BILI_VIDEO_URL'); self.env.pop('BILI_AUDIO_URL')
        self.env.update(BILI_MEDIA_DIR=str(p), EXPECTED_TOKEN='original-signature')
        r=self.measure(); self.assertEqual(r.returncode,0,r.stderr)
    def test_short_file_valid(self):
        r=self.measure('small'); self.assertEqual(r.returncode,0,r.stderr)
    def test_failures_reject_candidate(self):
        for mode in ('tls','timeout','ignored','partial','range'):
            with self.subTest(mode=mode):
                Path(self.env['MOCK_STATE']).unlink(missing_ok=True)
                r=self.measure(mode); self.assertNotEqual(r.returncode,0); self.assertEqual(r.stdout,'')
    def test_router_and_server_dry_run(self):
        hosts=Path(self.tmp.name)/'hosts'; hosts.write_text('127.0.0.1 localhost\n')
        self.env.update(BILI_HOSTS=str(hosts), BILI_DOMAINS='upos-hz-mirrorakam.akamaized.net',BILI_CANDIDATE_IPS='1.2.3.1 1.2.3.2')
        for script in ('openwrt/bili-openwrt-update.sh','server/bili-agh-update.sh'):
            with self.subTest(script=script):
                Path(self.env['MOCK_STATE']).unlink(missing_ok=True)
                r=subprocess.run(['sh',str(ROOT/script)],env=self.env,text=True,capture_output=True)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn('WOULD PIN: upos-hz-mirrorakam.akamaized.net -> 1.2.3.1 (500 bytes/s)',r.stdout)
                self.assertEqual(hosts.read_text(),'127.0.0.1 localhost\n')
        self.assertFalse((ROOT/'server/bili-agh-state.txt').exists())
    def test_all_failed_preserves_hosts(self):
        hosts=Path(self.tmp.name)/'hosts'; hosts.write_text('1.2.3.9 upos-hz-mirrorakam.akamaized.net # BiliCdnFix\n')
        original=hosts.read_text()
        self.env.update(MOCK_MODE='tls', BILI_HOSTS=str(hosts), BILI_DOMAINS='upos-hz-mirrorakam.akamaized.net', BILI_CANDIDATE_IPS='1.2.3.1')
        r=subprocess.run(['bash',str(ROOT/'macos/bili-cdn-fix.sh')],env=self.env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0); self.assertEqual(hosts.read_text(),original)
    def test_insufficient_rounds_rejected(self):
        self.assertNotEqual(self.measure(rounds='2').returncode,0)
    def test_macos_selection_dry_run_preserves_hosts(self):
        hosts=Path(self.tmp.name)/'hosts'; hosts.write_text('127.0.0.1 localhost\n')
        self.env.update(BILI_HOSTS=str(hosts), BILI_DOMAINS='upos-hz-mirrorakam.akamaized.net',BILI_CANDIDATE_IPS='1.2.3.1 1.2.3.2')
        self.env['BILI_DRY_RUN']='0'
        r=subprocess.run(['bash',str(ROOT/'macos/bili-cdn-fix.sh'),'--dry-run'],env=self.env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr); self.assertIn('BEST: 1.2.3.1  500 bytes/s',r.stdout)
        self.assertEqual(hosts.read_text(),'127.0.0.1 localhost\n'); self.assertFalse(list(hosts.parent.glob('hosts.bak*')))

class OfficialWorkflow(unittest.TestCase):
    def test_media_preparation_recovers_from_412_and_filters_codec(self):
        spec=importlib.util.spec_from_file_location('media_urls', ROOT/'tools/media-urls.py')
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        calls=[]
        def api(url):
            calls.append(url)
            if '/view?' in url: raise RuntimeError('HTTP 412')
            if '/pagelist?' in url: return {'code':0,'data':[{'cid':123}]}
            def track(codec,bw,path):
                return {'id':32,'codecid':codec,'bandwidth':bw,'codecs':'codec',
                        'baseUrl':'https://upos-hz-mirrorakam.akamaized.net/'+path,'backupUrl':[]}
            return {'code':0,'data':{'dash':{'video':[track(7,900,'avc'),track(12,400,'hevc')],
                                             'audio':[track(0,100,'audio')]}}}
        module.api=api
        with tempfile.TemporaryDirectory() as d, patch.object(sys,'argv',['media-urls.py','BV1Ra4y117kf','--video-codec','hevc','--output',d]):
            module.main()
            self.assertTrue((Path(d)/'video.url').read_text().endswith('/hevc\n'))
            self.assertTrue((Path(d)/'audio.url').exists())
            self.assertEqual((Path(d)/'video.url').stat().st_mode & 0o777,0o600)
        self.assertTrue(any('/pagelist?' in url for url in calls))
        self.assertTrue(any('cid=123' in url for url in calls))
    @unittest.skipUnless(sys.platform=='darwin','native macOS restore uses BSD sed')
    def test_official_macos_write_backup_and_restore(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d); hosts=p/'hosts'; original='127.0.0.1 localhost\n'; hosts.write_text(original)
            curl=p/'curl'; curl.write_text(MOCK); curl.chmod(0o755)
            for command in ('id','scutil','networksetup','dscacheutil','killall'):
                f=p/command; f.write_text('#!/bin/sh\n'+('echo 0\n' if command=='id' else 'echo mock\n')); f.chmod(0o755)
            env=dict(os.environ,PATH=d+':'+os.environ['PATH'], MOCK_STATE=str(p/'state'), BILI_DRY_RUN='0',
                     BILI_HOSTS=str(hosts), BILI_DOMAINS='upos-hz-mirrorakam.akamaized.net',
                     BILI_CANDIDATE_IPS='1.2.3.1 1.2.3.2',BILI_SPEED_BYTES='100',BILI_SPEED_ROUNDS='3',
                     BILI_VIDEO_URL='https://upos-hz-mirrorakam.akamaized.net/video?test',
                     BILI_AUDIO_URL='https://upos-hz-mirrorakam.akamaized.net/audio?test')
            script=str(ROOT/'macos/bili-cdn-fix.sh')
            run=subprocess.run(['bash',script],env=env,text=True,capture_output=True)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertIn('1.2.3.1 upos-hz-mirrorakam.akamaized.net # BiliCdnFix',hosts.read_text())
            backups=[f for f in p.glob('hosts.bak_*') if f.suffix not in ('.txt',)]
            self.assertTrue(any(f.read_text()==original for f in backups))
            self.assertTrue(list(p.glob('hosts.bak_*.dns.txt')))
            for key in ('BILI_VIDEO_URL','BILI_AUDIO_URL'): env.pop(key)
            restore=subprocess.run(['bash',script,'--restore'],env=env,text=True,capture_output=True)
            self.assertEqual(restore.returncode,0,restore.stderr); self.assertEqual(hosts.read_text(),original)

if __name__=='__main__': unittest.main()
