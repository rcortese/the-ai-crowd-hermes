import contextlib,importlib.util,io,json,pathlib,subprocess,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).parent
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/(name+'.py')); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
f=load('fleet_release'); r=load('runtime_check')
class Readiness(unittest.TestCase):
    def docker_ready(self):
        return {'Image':'new','RestartCount':0,'State':{'Status':'running','Running':True,'Health':{'Status':'healthy'}}}
    def test_docker_healthy_gateway_delayed(self):
        with patch.object(f,'inspect',return_value=self.docker_ready()),patch.object(f.time,'sleep'),patch.object(f,'probe',side_effect=[f.ProbeError('denholm','verify','READINESS'),None]) as p:
            f.healthy('denholm','new',commit='sha')
            self.assertEqual(p.call_count,2)
            self.assertTrue(all(c.args==('denholm','verify','sha') for c in p.call_args_list))
    def test_bounded_persistent_degradation(self):
        ticks=iter([0,0,0,0,601])
        with patch.object(f,'inspect',return_value=self.docker_ready()),patch.object(f.time,'monotonic',side_effect=lambda:next(ticks)),patch.object(f.time,'sleep'),patch.object(f,'probe',side_effect=f.ProbeError('denholm','verify','READINESS')):
            with self.assertRaisesRegex(RuntimeError,'readiness timeout; last=READINESS'): f.healthy('denholm','new')
    def test_permanent_gate_fails_immediately(self):
        for code in ('HTTP_401','AGENT_COMMIT','PYTHON_VERSION','HONCHO_CONFIG','IMPORT','INTERNAL','PROBE_PROTOCOL'):
            with self.subTest(code=code),patch.object(f,'inspect',return_value=self.docker_ready()),patch.object(f.time,'sleep') as sleep,patch.object(f,'probe',side_effect=f.ProbeError('d','verify',code)) as p:
                with self.assertRaises(f.ProbeError): f.healthy('d','new')
                self.assertEqual(p.call_count,1); sleep.assert_not_called()
    def test_wrong_image_restart_and_exit_never_probe(self):
        for field,value in [('Image','wrong'),('RestartCount',1),('State',{'Status':'exited'})]:
            d=self.docker_ready(); d[field]=value
            with patch.object(f,'inspect',return_value=d),patch.object(f,'probe') as p:
                with self.assertRaises(RuntimeError): f.healthy('d','new')
                p.assert_not_called()
    def test_rollback_waits_authenticated_health(self):
        with patch.object(f,'inspect',return_value=self.docker_ready()),patch.object(f,'probe') as p:
            f.healthy('d','new'); self.assertEqual(p.call_args.args,('d','health',''))
    def test_probe_strict_safe_diagnostics(self):
        for raw,expected in [(b'{"result":"FAIL","code":"READINESS"}','READINESS'),(b'{"result":"FAIL","code":"secret-token"}','PROBE_FAILED'),(b'secret-token','PROBE_FAILED')]:
            exc=subprocess.CalledProcessError(1,['fake'],output=raw,stderr=b'secret-token')
            with patch.object(f,'run',side_effect=exc):
                with self.assertRaises(f.ProbeError) as caught: f.probe('d','verify')
                self.assertEqual(caught.exception.code,expected); self.assertNotIn('secret-token',str(caught.exception))
    def test_success_protocol_and_timeout(self):
        with patch.object(f,'run',return_value=b'log\n{"result":"PASS"}\n'): f.probe('d','health')
        with patch.object(f,'run',return_value=b'junk'):
            with self.assertRaisesRegex(f.ProbeError,'PROBE_PROTOCOL'): f.probe('d','health')
        with patch.object(f,'run',side_effect=subprocess.TimeoutExpired(['secret-token'],35)):
            with self.assertRaisesRegex(f.ProbeError,'PROBE_TIMEOUT'): f.probe('d','health')
    def test_entrypoint_never_leaks_exception(self):
        for exc,code in [(r.GateError('READINESS'),'READINESS'),(ValueError('secret-token'),'INTERNAL'),(r.urllib.error.HTTPError('secret-token',401,'secret-token',{},None),'HTTP_401')]:
            with patch.object(r,'main',side_effect=exc),contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(r.entrypoint(),1)
            self.assertEqual(json.loads(out.getvalue()),{'result':'FAIL','code':code})
    def test_predecessor_terminal_hash_and_isolation(self):
        with tempfile.TemporaryDirectory() as td,patch.object(f,'STACK',pathlib.Path(td)):
            p=f.STACK/'state/private/backups/fleet-release-20260922/transaction.json'; p.parent.mkdir(parents=True)
            for phase in ('ROLLED_BACK','ROLLING_BACK'):
                raw=json.dumps({'phase':phase}).encode(); p.write_bytes(raw); m={'predecessor_transaction_sha':f.sha(raw)}
                if phase=='ROLLED_BACK': f.check_predecessor(m)
                else:
                    with self.assertRaisesRegex(RuntimeError,'not rolled back'): f.check_predecessor(m)
            with self.assertRaisesRegex(RuntimeError,'drift'): f.check_predecessor({'predecessor_transaction_sha':'wrong'})
        self.assertEqual(f.STATE.name,'fleet-release-20260922-r2')
    def test_six_service_transaction_delayed_denholm(self):
        from contextlib import ExitStack
        with tempfile.TemporaryDirectory() as td,ExitStack() as es:
            root=pathlib.Path(td); compose=root/'compose.yaml'; compose.write_bytes(b'old')
            (root/'compose.candidate.yaml').write_bytes(b'new'); (root/'release.json').write_bytes(b'{}')
            (root/'review.json').write_text(json.dumps({'verdict':'APPROVED WITHOUT CHANGES','manifest_sha':f.sha(b'{}')}))
            for name,value in [('ROOT',root),('COMPOSE',compose),('STATE',root/'retry-state')]: es.enter_context(patch.object(f,name,value))
            for name in ('check','install_source','snapshot'): es.enter_context(patch.object(f,name))
            es.enter_context(patch.object(f,'container',return_value=['configure']))
            es.enter_context(patch.object(f,'run',return_value=b'{"config_sha":"new"}'))
            es.enter_context(patch.object(f,'inspect',return_value=self.docker_ready()))
            es.enter_context(patch.object(f.time,'sleep'))
            calls=[]
            def probe(s,mode,*args,**kwargs):
                calls.append((s,mode))
                if s=='denholm' and mode=='verify' and calls.count((s,mode))==1: raise f.ProbeError(s,mode,'READINESS')
            es.enter_context(patch.object(f,'probe',side_effect=probe))
            m={'services':{s:{'config_sha':'old','image':'new','base_image':'old','agent_commit':'sha'} for s in f.ORDER}}
            f.apply(m)
            state=json.loads((f.STATE/'transaction.json').read_text())
            self.assertEqual(state['phase'],'SUCCEEDED'); self.assertEqual(state['attempted'],f.ORDER)
            self.assertEqual(calls.count(('denholm','verify')),2)
            self.assertEqual(calls[-1],('moss','verify'))
    def test_real_http_probe_subprocess_delayed_and_unauthorized(self):
        import http.server,threading,os
        state={'count':0,'unauthorized':False}
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                state['count']+=1
                status=401 if state['unauthorized'] else 200
                self.send_response(status); self.end_headers()
                self.wfile.write(json.dumps({'readiness':{'status':'starting' if state['count']==1 else 'ready'}}).encode())
            def log_message(self,*args): pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        t=threading.Thread(target=server.serve_forever,daemon=True); t.start()
        try:
            with tempfile.TemporaryDirectory() as td:
                env=dict(os.environ,HERMES_HOME=td,API_SERVER_PORT=str(server.server_port),API_SERVER_KEY='fixture-only')
                results=[subprocess.run([sys.executable,str(ROOT/'runtime_check.py'),'health'],env=env,capture_output=True,timeout=15) for _ in range(2)]
                self.assertEqual([x.returncode for x in results],[1,0]); self.assertEqual(json.loads(results[0].stdout)['code'],'READINESS')
                state['unauthorized']=True
                p=subprocess.run([sys.executable,str(ROOT/'runtime_check.py'),'health'],env=env,capture_output=True,timeout=15)
                self.assertEqual(json.loads(p.stdout)['code'],'HTTP_401'); self.assertNotIn(b'fixture-only',p.stdout+p.stderr)
        finally: server.shutdown(); server.server_close(); t.join()
if __name__=='__main__': unittest.main()
