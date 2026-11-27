"""Recording Docker executable for the installed host deployment checks."""

import sys


def docker_fixture(scratch):
    fakebin = scratch / "fake tools"
    fakebin.mkdir()
    docker = fakebin / "docker"
    docker.write_text(
        f"#!{sys.executable}\n"
        + """
import hashlib, json, os, pathlib, signal, sys, time
a = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\\n')
if os.environ.get('HANG_PROBE') or (os.environ.get('HANG_BUILD') and a[:1] == ['build']):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(os.environ['DOCKER_PID']).write_text(str(os.getpid()))
    os.write(1, b'partial stdout before hang\\n')
    os.write(2, b'last stderr before hang\\n')
    os.close(1); os.close(2)
    time.sleep(60)
phase = os.environ.get('STREAM_PHASE')
if (phase == 'query' and a[:2] == ['version', '--format']) or (phase == 'action' and a == ['version']):
    # Exceed a pipe's capacity and omit newlines: forwarding must not depend
    # on line buffering or wait for the process to exit.
    os.write(1, (phase + '-stdout|').encode() * 8192)
    os.write(2, (phase + '-stderr').encode())
    release = pathlib.Path(os.environ['STREAM_RELEASE'])
    until = time.monotonic() + 10
    while not release.exists() and time.monotonic() < until: time.sleep(0.01)
    if not release.exists(): sys.exit(8)
if os.environ.get('FAIL_QUERY') and a[:2] == ['version', '--format']:
    os.write(1, b'query failure on stdout\\n')
    os.write(2, b'query failure on stderr\\n')
    sys.exit(9)
if os.environ.get('FAIL_INSPECT') and a[:2] == ['image', 'inspect'] and '--format' not in a:
    os.write(1, b'inspect failure on stdout\\n')
    os.write(2, b'inspect failure on stderr\\n')
    sys.exit(1)
if a[:2] == ['ps', '--all'] and 'label=org.glowcap.rooms.member=true' in a:
    print(os.environ.get('MEMBER_ROWS', ''))
image = 'sha256:' + 'a' * 64
if a[:2] == ['volume', 'ls'] and os.environ.get('EXISTING_VOLUME'):
    print('glowcap-rooms-session-state\\nglowcap-rooms-directory-state\\noperator-extra-volume')
    if os.environ.get('CUSTOM_VOLUMES'): print('custom-session\\ncustom-directory')
if a[:1] == ['compose'] and a[-3:] == ['config', '--format', 'json']:
    prefix = 'custom-' if os.environ.get('CUSTOM_VOLUMES') else 'glowcap-rooms-'
    names = ['session', 'directory'] if os.environ.get('CUSTOM_VOLUMES') else ['session-state', 'directory-state']
    model = {'services': {}, 'volumes': {}}
    for service, source, target, name in zip(['session', 'directory'], ['session-state', 'directory-state'], ['/session-state', '/state'], names):
        model['services'][service] = {'volumes': [{'type': 'volume', 'source': source, 'target': target}]}
        model['volumes'][source] = {'name': prefix + name, 'external': bool(os.environ.get('EXTERNAL_VOLUMES'))}
    if os.environ.get('BIND_VOLUME'): model['services']['session']['volumes'][0]['type'] = 'bind'
    if os.environ.get('SHARED_VOLUME'): model['volumes']['directory-state']['name'] = model['volumes']['session-state']['name']
    print(json.dumps(model))
if a[:2] == ['volume', 'rm'] and os.environ.get('FAIL_VOLUME') == a[-1]:
    sys.exit(9)
if a[:1] == ['build']:
    if os.environ.get('FAIL_BUILD'):
        os.write(1, b'build failure on stdout\\n')
        os.write(2, b'build failure on stderr\\n')
        sys.exit(9)
    root = pathlib.Path(a[-1])
    receipt = 'share/glowcap/installation.manifest'
    expected = {receipt}
    for row in (root / receipt).read_text().splitlines():
        digest, mode, name = row.split(' ', 2)
        expected.add(name)
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
    assert {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()} == expected
    assert a[a.index('--platform') + 1] in ('linux/amd64', 'linux/arm64')
    assert pathlib.Path(a[a.index('--file') + 1]).is_relative_to(root)
    pathlib.Path(a[a.index('--iidfile') + 1]).write_text(image + '\\n')
    pathlib.Path(os.environ['DOCKER_LOG'] + '.label').write_text(a[a.index('--label') + 1].split('=', 1)[1])
elif a[:2] == ['image', 'inspect'] and 'Labels' in ' '.join(a):
    label = pathlib.Path(os.environ['DOCKER_LOG'] + '.label')
    print(label.read_text() if label.exists() else '<no value>')
elif a[:2] == ['image', 'inspect']: print(image)
elif 'exec' in a and 'member-session' in a:
    if 'issue' in a:
        print(json.dumps({'ok': True, 'id': 'deployment-bot', 'link': 'ocapn://fixture/s/fixture-bearer'}))
        if os.environ.get('FAIL_MEMBER_ISSUE'):
            print('fixture-bearer', file=sys.stderr)
            sys.exit(9)
    else: print(json.dumps({'ok': True}))
elif 'exec' in a:
    # One distinct answer per operand, so a print that swaps or drops a read fails.
    page = '' if os.environ.get('ROOMS_FIXTURE_NO_PAGE') else 'https://glowcap.org/rooms/app/?server=http%3A%2F%2Flocalhost%3A8080%2F'
    answers = [('page', page), ('locator', 'ocapn://fixture-directory.tcp'), ('revision', 'fixture-browser-revision'),
               ('capabilities', 'ROOMS-OPERATOR ocapn://fixture-directory.tcp/s/operator'),
               ('--print-link', 'ocapn://127.0.0.1%3A9300.tcp/s/eA?captp-websocket=ws%3A%2F%2F127.0.0.1%3A9300%2Fcaptp&trace-publish=ws%3A%2F%2F127.0.0.1%3A9300%2Fpublish'),
               ('--file=/session-state/management.sturdyref', 'ocapn://management'),
               ('--file=/run/rooms-session/use.sturdyref', 'ocapn://fixture')]
    print(dict(answers)[a[-1]])
if a[:1] == ['compose'] and '--project-directory' in a:
    config = pathlib.Path(a[a.index('-f') + 1]).parent
    project = pathlib.Path(a[a.index('--project-directory') + 1])
    if '--project-name' in a:
        assert pathlib.Path(a[a.index('-f') + 1]).is_file()
        assert a[a.index('--project-name') + 1] == 'glowcap-member-' + project.name + '-' + (project / 'project-id').read_text()
    else: assert project == config
"""
    )
    docker.chmod(0o755)
    return fakebin
