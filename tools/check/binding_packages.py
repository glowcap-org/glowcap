"""Rehearse binding packages without publishing, for `bindings-package-check`.

Requires the devcontainer tools and installed C archives. Packages and consumers
live in a temporary directory outside the checkout. Registry downloads may
populate tool caches; no registry writes or user package installs occur.
The optional language argument selects one proof. Child failures stop the
check, child deadlines bound hangs, and temporary installs are removed on exit.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import tomllib

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=ROOT, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True, timeout=600)


def python_package(work, env):
    source = work / 'python'
    shutil.copytree(ROOT / 'bindings/python', source,
                    ignore=shutil.ignore_patterns('__pycache__', '*.egg-info', 'build', '.venv'))
    distributions = work / 'dist'
    run('uv', 'build', '--sdist', '--out-dir', str(distributions), str(source))
    sdist, = distributions.glob('*.tar.gz')
    run('uv', 'build', '--wheel', '--out-dir', str(distributions), str(sdist))
    wheel, = distributions.glob('*.whl')
    venv = work / 'venv'
    run('uv', 'venv', '--python', shutil.which('python3'), str(venv))
    python = str(venv / 'bin/python')
    run('uv', 'pip', 'install', '--python', python, '--no-deps', str(wheel))
    run(python, '-I', '-c', textwrap.dedent('''\
        import asyncio, importlib, pkgutil
        from pathlib import Path
        import glowcap
        for module in pkgutil.walk_packages(glowcap.__path__, glowcap.__name__ + '.'):
            importlib.import_module(module.name)
        package = Path(glowcap.__file__).parent
        assert (package / 'py.typed').is_file()
        assert (package / 'c-abi-resolve.json').is_file()
        async def smoke():
            host = glowcap.Host()
            await host.close()
        asyncio.run(smoke())
        '''), cwd=work, env=env)


def rust_package(work, env):
    target = work / 'cargo'
    run('cargo', 'package', '--manifest-path', str(ROOT / 'bindings/rust/Cargo.toml'),
        '--allow-dirty', '--no-verify', '--target-dir', str(target))
    archive, = (target / 'package').glob('*.crate')
    with tarfile.open(archive) as package:
        package.extractall(work / 'crate', filter='data')
    crate, = (work / 'crate').iterdir()
    consumer = work / 'consumer'
    (consumer / 'src').mkdir(parents=True)
    version = tomllib.loads((crate / 'Cargo.toml').read_text())['package']['version']
    (consumer / 'Cargo.toml').write_text(textwrap.dedent(f'''\
        [package]
        name = "glowcap-package-consumer"
        version = "0.0.0"
        edition = "2024"
        [dependencies]
        glowcap = {{ path = {json.dumps(str(crate))}, version = "={version}", features = ["async", "loam", "iroh", "webrtc", "relay", "onion"] }}
        '''))
    (consumer / 'src/main.rs').write_text('fn main() { let _context = glowcap::Context::new().unwrap(); }\n')
    run('cargo', 'run', '--manifest-path', str(consumer / 'Cargo.toml'),
        '--target-dir', str(target), cwd=work,
        env=dict(env, LD_LIBRARY_PATH=env['GLOWCAP_LIB_DIR'],
                 DYLD_LIBRARY_PATH=env['GLOWCAP_LIB_DIR']))
    # docs.rs builds without the native SDK. Rustdoc must also accept the
    # extracted crate and resolve its public links without a source checkout.
    run('cargo', 'doc', '--manifest-path', str(crate / 'Cargo.toml'), '--lib',
        '--no-deps', '--all-features', '--target-dir', str(target), cwd=work,
        env=dict({key: value for key, value in env.items() if key != 'GLOWCAP_LIB_DIR'},
                 DOCS_RS='1', GLOWCAP_STRICT='1',
                 RUSTDOCFLAGS='-D rustdoc::broken_intra_doc_links'))


def racket_package(work, env):
    run('raco', 'pkg', 'create', '--source', '--format', 'zip', '--dest', str(work),
        str(ROOT / 'bindings/racket'))
    scope = work / 'racket-pkgs'
    # The disposable scope has no dependency database. Use the devcontainer's
    # installed dependencies through the existing collection links at load time.
    run('raco', 'pkg', 'install', '--scope-dir', str(scope), '--no-setup',
        '--deps', 'force', '--name', 'glowcap', str(work / 'racket.zip'))
    expression = f'''(parameterize ([current-library-collection-links
        (cons (string->path {json.dumps(str(scope / 'links.rktd'))})
              (current-library-collection-links))])
      (for ([module '(glowcap/glowcap glowcap/glowcap-tcp glowcap/glowcap-inproc
                     glowcap/glowcap-onion glowcap/glowcap-iroh glowcap/glowcap-webrtc
                     glowcap/glowcap-relay)])
        (dynamic-require module #f))
      (define make-host (dynamic-require 'glowcap/glowcap 'make-fresh-host))
      ((dynamic-require 'glowcap/glowcap 'host-close!) (make-host)))'''
    run('racket', '-e', expression, cwd=work, env=env)


def typescript_package(work, env):
    # Deno checks cross-package imports, public declaration generation and the
    # actual publish include/exclude lists. --allow-dirty permits review edits;
    # --dry-run is unconditional, so this command never uploads anything.
    run('deno', 'publish', '--dry-run', '--allow-dirty', cwd=ROOT / 'bindings/ts', env=env)


def main():
    proofs = {'python': python_package, 'rust': rust_package,
              'racket': racket_package, 'typescript': typescript_package}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('language', nargs='?', choices=proofs)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='glowcap-packages-') as temporary:
        work = Path(temporary)
        env = dict(os.environ, GLOWCAP_LIB_DIR=str(ROOT / 'zig-out/lib'),
                   GLOWCAP_SKIP_DOWNLOAD='1', GLOWCAP_CACHE_DIR=str(work / 'cache'))
        for name in ([args.language] if args.language else proofs):
            print(f'binding package: {name}', flush=True)
            proofs[name](work, env)
            print(f'binding package: {name} passed', flush=True)


if __name__ == '__main__':
    main()
