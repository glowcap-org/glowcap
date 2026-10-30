"""Exercise production curl downloaders for the check and bindings gates.

A local HTTP mirror supplies valid archives. A poisoned curl configuration
adds a header that makes the mirror refuse requests. Each loader must ignore
that configuration and install exactly the checked payload. No SDK is needed.
"""
import functools
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DownloadPolicy(unittest.TestCase):
    def test_curl_configuration_cannot_change_release_requests(self):
        payload = b'checked release library\n'
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            member = tarfile.TarInfo('lib/libglowcap_ocapn.a')
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        content = stream.getvalue()
        name = 'glowcap-c-v0.1.0-x86_64-linux.tar.gz'
        sums = f'{hashlib.sha256(content).hexdigest()}  {name}\n'.encode()
        requests = []

        class Mirror(BaseHTTPRequestHandler):
            def do_GET(self):
                poisoned = self.headers.get('X-Untrusted-Curl-Config') is not None
                requests.append((self.path, poisoned))
                self.send_response(403 if poisoned else 200)
                self.end_headers()
                self.wfile.write(sums if self.path.endswith('/SHA256SUMS') else content)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Mirror)
        thread = threading.Thread(target=functools.partial(server.serve_forever, poll_interval=0.01))
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='glowcap-download-') as temporary:
                work = Path(temporary)
                config = work / 'curl-config'
                config.mkdir()
                (config / '.curlrc').write_text('header = "X-Untrusted-Curl-Config: injected"\n')
                env = dict(os.environ, CURL_HOME=str(config), GLOWCAP_ALLOW_INSECURE='1',
                           NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
                url = f'http://127.0.0.1:{server.server_port}/v0.1.0/{name}'

                def run(args, **kwargs):
                    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                                          text=True, timeout=15, **kwargs)

                # Prove the injected configuration reaches real curl before
                # expecting production downloaders to suppress it.
                response = run(['curl', '-fsS', url])
                self.assertNotEqual(response.returncode, 0)
                self.assertTrue(requests[-1][1])
                requests.clear()

                commands = {}
                cache = work / 'cache'
                shell_env = dict(env, GLOWCAP_DOWNLOAD='1', GLOWCAP_SKIP_DOWNLOAD='0',
                                 GLOWCAP_STRICT='1', GLOWCAP_CACHE_DIR=str(cache),
                                 GLOWCAP_REPO_ROOT=str(ROOT),
                                 GLOWCAP_RELEASE_BASE_URL=url.rsplit('/v0.1.0/', 1)[0])
                commands['shell'] = (['sh', 'tools/c-abi/fetch-c-abi.sh', '--version', '0.1.0',
                                      '--target', 'x86_64-linux'], shell_env,
                                     cache / '0.1.0/x86_64-linux/lib/libglowcap_ocapn.a', payload)

                destination = work / 'download'
                commands['typescript'] = (['deno', 'eval', '''
import { curlDownload } from "./bindings/ts/runtime/internal/ffi/load.ts";
if (!curlDownload(Deno.args[0], Deno.args[1], "glowcap-test", 1048576)) Deno.exit(1);
''', url, str(destination)], env, destination, content)
                racket = work / 'download.rkt'
                racket.write_text(f'''#lang racket/base
(require racket/system (submod (file {json.dumps(str(ROOT / 'bindings/racket/private/lib-resolve.rkt'))}) download-test-support))
(unless (curl-download (find-executable-path "curl") {json.dumps(url)}
                       (string->path {json.dumps(str(destination))}) "glowcap-test" 1048576)
  (exit 1))
''')
                commands['racket'] = (['racket', str(racket)], env, destination, content)
                rust = work / 'download.rs'
                rust.write_text(f'''#[path = {json.dumps(str(ROOT / 'bindings/rust/release_download.rs'))}]
mod release_download;
fn main() {{
    let args: Vec<String> = std::env::args().collect();
    assert!(release_download::download(&args[1], std::path::Path::new(&args[2]),
                                      "glowcap-test", 1048576, &[]).unwrap());
}}
''')
                binary = work / 'rust-download'
                compiled = run(['rustc', str(rust), '-o', str(binary)])
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                commands['rust'] = ([str(binary), url, str(destination)], env, destination, content)
                for port, (args, environment, output, expected) in commands.items():
                    with self.subTest(port=port):
                        requests.clear()
                        if output.exists():
                            output.unlink()
                        result = subprocess.run(args, cwd=ROOT, env=environment, capture_output=True,
                                                text=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(output.read_bytes(), expected)
                        self.assertTrue(requests)
                        self.assertFalse(any(poisoned for _, poisoned in requests), requests)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


if __name__ == '__main__':
    unittest.main()
