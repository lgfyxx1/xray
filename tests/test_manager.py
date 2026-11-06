"""Security regressions and config checks against an actual official Xray binary."""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'xray-reality.sh'
CORE = os.environ.get('XRAY_TEST_BIN')


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.state = dict(PROTO='vless-reality', PORT='443',
            UUID='9e446e9e-a212-4bfc-86c7-b329efeb0bbb', PASSWORD='',
            PRIVKEY='qNE_eJb3bDfLfBDRIWu7xj8x0GHFQL7GWRuCFl_zqkA',
            PUBKEY='tNFH4o9S5f2eWlmkpW0bPMq8Ei-RlFx068lgmBOh_jE',
            SHORTID='0011223344556677', DEST='www.microsoft.com',
            SNI='www.microsoft.com', DOMAIN='', WS_PATH='', GRPC_SVC='',
            SS_METHOD='', ADDR='203.0.113.10', NAME='测试节点 " # & $(literal)')

    def shell(self, body, state=None, check=True):
        d = state or self.state
        text = 'source '+shlex.quote(str(SCRIPT))+'\n'
        text += '\n'.join(k+'='+shlex.quote(v) for k,v in d.items())+'\n'
        text += 'SSL_DIR='+shlex.quote(str(self.dir))+'\n'+body
        result = subprocess.run(['bash','-c',text], text=True, capture_output=True)
        if check and result.returncode:
            self.fail(result.stdout+'\n'+result.stderr)
        return result

    def state_tool(self, op, *args, state=None, check=True):
        return self.shell('state_tool '+shlex.join([op,*map(str,args)]), state, check)

    def test_metadata_does_not_execute_commands(self):
        marker = self.dir/'executed'
        self.state['NAME'] = '$(touch '+str(marker)+'); `touch '+str(marker)+'`'
        legacy = self.dir/'legacy.env'
        legacy.write_text('\n'.join(k+'='+v for k,v in self.state.items())+'\n')
        result = self.shell('XRAY_META_FILE='+shlex.quote(str(legacy))+'\n_reload_meta\nstate_tool save')
        self.assertFalse(marker.exists())
        self.assertEqual(json.loads(result.stdout), self.state)

    def test_json_metadata_roundtrip(self):
        path = self.dir/'meta.json'
        path.write_text(self.state_tool('save').stdout)
        result = self.shell('XRAY_META_FILE='+shlex.quote(str(path))+'\n_reload_meta\nstate_tool save')
        self.assertEqual(json.loads(result.stdout),self.state)

    def test_metadata_rejects_extra_fields(self):
        path=self.dir/'bad.json'
        path.write_text(json.dumps(dict(self.state, EVIL='test')))
        self.assertNotEqual(self.state_tool('load',path,'/unused',check=False).returncode,0)

    def test_rejects_injected_domains_ports_and_controls(self):
        for field, value in [('PORT','0443'),('PORT','65536'),('PORT','1e3'),
            ('DEST','good.com\",\"show\":true'),('ADDR','999.999.999.999/xx'),
            ('NAME','line\nPROTO=other')]:
            with self.subTest(field=field,value=value):
                d=dict(self.state); d[field]=value
                self.assertNotEqual(self.state_tool('validate',state=d,check=False).returncode,0)

    def test_uri_names_and_ipv6_are_encoded(self):
        self.state['ADDR']='2001:db8::1'
        link=self.state_tool('link').stdout.strip()
        u=urlsplit(link)
        self.assertEqual(u.hostname,'2001:db8::1')
        self.assertEqual(unquote(u.fragment),self.state['NAME'])

    def test_vmess_preserves_unicode_and_quotes(self):
        d=self.tls_state('vmess-ws-tls')
        link=self.state_tool('link',state=d).stdout.strip()
        v=json.loads(base64.b64decode(link.removeprefix('vmess://')))
        self.assertEqual(v['ps'],d['NAME'])
        self.assertEqual(v['path'],'/'+d['WS_PATH'])

    def release(self, **kwargs):
        r=dict(tag_name='v26.10.31',draft=False,prerelease=False,assets=[dict(
            name='Xray-linux-64.zip',digest='sha256:'+'a'*64,
            browser_download_url='https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-64.zip')])
        r.update(kwargs)
        path=self.dir/'release.json'; path.write_text(json.dumps(r))
        return path

    def test_release_requires_stable_version_and_digest(self):
        self.assertEqual(self.state_tool('release',self.release(),'64','26.10.31').stdout.splitlines()[0],'v26.10.31')
        for args in [dict(prerelease=True),dict(draft=True),dict(tag_name='v26.10.21'),dict(assets=[])]:
            with self.subTest(args=args):
                self.assertNotEqual(self.state_tool('release',self.release(**args),'64','26.10.31',check=False).returncode,0)
        for digest in ['',None,'sha256:short']:
            r=json.loads(self.release().read_text()); r['assets'][0]['digest']=digest
            path=self.dir/'release.json'; path.write_text(json.dumps(r))
            self.assertNotEqual(self.state_tool('release',path,'64','26.10.31',check=False).returncode,0)

    def test_release_rejects_external_download_url(self):
        path=self.release(); r=json.loads(path.read_text())
        r['assets'][0]['browser_download_url']='https://evil.example/xray.zip'
        path.write_text(json.dumps(r))
        self.assertNotEqual(self.state_tool('release',path,'64','26.10.31',check=False).returncode,0)

    def test_installer_checksum_is_mandatory(self):
        # Controlled download replacement, never executes or downloads remote code.
        result=self.shell('https_get() { printf "untrusted" > "$3"; }\n'
            'sha256sum() { shasum -a 256 "$@"; }\ndownload_installer',check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SHA256',result.stderr)

    def tls_state(self, proto):
        return dict(self.state,PROTO=proto,DOMAIN='node.example.com',
            WS_PATH='0123456789abcdef',GRPC_SVC='0123456789abcdef',
            PASSWORD='a'*32, SS_METHOD='aes-256-gcm')

    @unittest.skipUnless(CORE,'set XRAY_TEST_BIN to the verified official Xray binary')
    def test_all_eight_protocols_with_official_core(self):
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-keyout',str(self.dir/'privkey.pem'),'-out',str(self.dir/'fullchain.pem'),
            '-subj','/CN=node.example.com','-days','1'],check=True,capture_output=True)
        protocols=['vless-reality','ss-ws-tls']+[p+'-'+t+'-tls'
            for p in ('vless','vmess','trojan') for t in ('ws','grpc')]
        for proto in protocols:
            with self.subTest(protocol=proto):
                d=self.state if proto=='vless-reality' else self.tls_state(proto)
                config=json.loads(self.state_tool('config',state=d).stdout)
                self.assertEqual(config['routing']['domainStrategy'],'IPOnDemand')
                self.assertIn('169.254.0.0/16',config['routing']['rules'][0]['ip'])
                path=self.dir/'config.json'; path.write_text(json.dumps(config))
                result=subprocess.run([CORE,'run','-test','-config',str(path)],text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
                self.assertTrue(self.state_tool('link',state=d).stdout.strip())


if __name__=='__main__':
    unittest.main(verbosity=2)
