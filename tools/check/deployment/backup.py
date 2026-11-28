"""Run the published backup recipe against stopped, prepared and restored members."""

import json
import subprocess
import sys
import tarfile
from pathlib import Path


def backup(deploy, scratch):
    deploy.call("up", "--image", "fixture:rooms")
    deploy.call("bots", "init", "--room", "workshop", "scout")
    deploy.call("bots", "init", "waiting")
    root = deploy.workspace
    stores = scratch / "volumes"
    stores.mkdir()
    fixture = scratch / "backup-tools"
    fixture.mkdir()
    (fixture / "glowcap").symlink_to(deploy.binary)
    script = fixture / "docker"
    script.write_text(
        f"#!{sys.executable}\n"
        + """
import json, os, pathlib, sys
a = sys.argv[1:]
root = pathlib.Path(os.environ['STORES'])
with (root.parent/'backup-calls').open('a') as calls:
    calls.write(json.dumps(a) + '\\n')
if os.environ.get('PRIVATE_CONFIG_FAILURE') and a[-3:] == ['config', '--format', 'json']:
    print('fixture-private-value')
    print('fixture-private-value', file=sys.stderr)
    sys.exit(1)
if a[:1] == ['compose'] and a[-3:] == ['config', '--format', 'json']:
    p = pathlib.Path(a[a.index('--project-directory')+1])
    model = json.loads((p/'fixtures.json').read_text())
    if '--project-name' in a:
        assert a[a.index('--project-name')+1] == 'glowcap-member-' + p.name + '-' + (p/'project-id').read_text()
        assert str(p.parent.parent/'bots.override.yml') in a
        if (p/'compose.override.yml').exists():
            assert str(p/'compose.override.yml') in a
            model['volumes'].update(json.loads((p/'compose.override.yml').read_text())['volumes'])
    print(json.dumps(model))
elif a[:2] == ['volume', 'ls']:
    assert a[2:4] == ['--quiet','--filter']
    for expr in a[4::2]:
        name = expr.removeprefix('name=')
        if (root/name).is_dir(): print(name)
elif a[:2] == ['volume', 'inspect']:
    assert (root/a[2]).is_dir()
elif a == ['volume','create']:
    (root/'restored-session').mkdir()
    print('restored-session')
elif a[:1] == ['run'] and '-i' in a:
    directory = root/a[a.index('-v')+1].split(':')[0]
    assert directory.is_dir()
    os.execvp('tar',['tar','xzpf','-','-C',str(directory)])
elif a[:1] == ['run'] and '/volume:ro' in a[a.index('-v')+1]:
    directory = root/a[a.index('-v')+1].split(':')[0]
    assert directory.is_dir()
    os.execvp('tar',['tar','czf','-','-C',str(directory),'.'])
elif a[:1] == ['compose'] and a[-4:] == ['ps', '--all', '--no-trunc', '--quiet']:
    if (os.environ.get('STALE_MOUNT') or os.environ.get('RUNNING') or os.environ.get('STALE_FILE')) and pathlib.Path(a[a.index('--project-directory')+1]).name == 'scout': print('member-container')
elif a[:1] == ['inspect'] and a[-1] == 'member-container':
    session = 'older-data' if os.environ.get('STALE_MOUNT') else 'restored-session'
    mounts = [dict(Type='volume', Destination='/session-state', Name=session, Source='/volume'),
              dict(Type='bind', Destination='/policy', Source=str(root.parent/('other-policy' if os.environ.get('STALE_FILE') else 'policy'))),
              dict(Type='bind', Destination='/run/secrets/grant', Source=str(root.parent/'grant'))]
    print('member-container\\tmember-session\\t' + json.dumps(mounts))
else:
    real = os.environ['OTHER_DOCKER']
    os.execv(real,[real,*a])
"""
    )
    script.chmod(0o700)
    deploy.env.update(
        STORES=str(stores),
        OTHER_DOCKER=str(Path(deploy.env["PATH"].split(":")[0]) / "docker"),
        PATH=f"{fixture}:{deploy.env['PATH']}",
    )
    guide = (Path(__file__).resolve().parents[3] / "apps/rooms/web/deploy/backup.md").read_text()
    archive = guide.split("sh -eu -s -- \"$backup\" <<'SH'\n", 1)[1].split("\nSH\n", 1)[0]

    def save(label):
        dest = scratch / label
        dest.mkdir()
        manifest = deploy.call("backup-plan", "--files-only", "waiting").stdout
        (dest / "mounts").write_text(manifest)
        result = subprocess.run(
            ["sh", "-eu", "-s", "--", str(dest)],
            input=archive,
            text=True,
            cwd=root,
            env=deploy.env,
            capture_output=True,
            timeout=15,
        )
        assert result.returncode == 0, result
        return dest, manifest

    def configure(project, services, create):
        volumes: dict[str, dict[str, str]] = {}
        configured: dict[str, dict[str, list[dict[str, str]]]] = {}
        for service, mounts in services.items():
            rows = []
            for key, target in mounts.items():
                name = ("base" if project == root else project.name) + "-" + key
                volumes[key] = {"name": name}
                rows.append({"type": "volume", "source": key, "target": target})
                if create:
                    (stores / name).mkdir()
                    (stores / name / "identity").write_text(name)
            configured[service] = {"volumes": rows}
        (project / "fixtures.json").write_text(json.dumps({"services": configured, "volumes": volumes}))

    configure(root, {"session": {"base-session": "/session-state"}, "directory": {"base-directory": "/state"}}, True)
    scout, waiting = (root / "bots" / nick for nick in ("scout", "waiting"))
    services = {
        "member-session": {"identity": "/session-state"},
        "bot": {"agent": "/bot-state", "home": "/bot-state/home"},
    }
    configure(scout, services, True)
    configure(waiting, services, False)
    (root / "bots.override.yml").write_text("{}")
    (stores / "shared-inputs").mkdir()
    for member in (scout, waiting):
        model = json.loads((member / "fixtures.json").read_text())
        model["services"]["bot"]["volumes"].append(
            {"type": "volume", "source": "inputs", "target": "/shared-inputs", "read_only": True}
        )
        model["volumes"]["inputs"] = {"name": "shared-inputs", "external": True}
        (member / "fixtures.json").write_text(json.dumps(model))
    external_home = scratch / "external agent home"
    external_home.mkdir()
    model = json.loads((scout / "fixtures.json").read_text())
    for filename in ("policy", "grant"):
        (scratch / filename).write_text("fixture-private-value")
    model.update(
        configs={"policy": {"file": str(scratch / "policy")}},
        secrets={"grant": {"file": str(scratch / "grant")}, "token": {"environment": "FIXTURE_TOKEN"}},
    )
    model["services"]["member-session"].update(
        configs=[{"source": "policy"}], secrets=[{"source": "grant"}, {"source": "token"}]
    )
    model["services"]["bot"]["volumes"].append({"type": "bind", "source": str(external_home), "target": "/home/node"})
    (scout / "fixtures.json").write_text(json.dumps(model))
    assert "MissingDeploymentVolume" in deploy.call("backup-plan", ok=False).stderr
    failure = deploy.call("backup-plan", env={"PRIVATE_CONFIG_FAILURE": "1"}, ok=False)
    assert not failure.stdout and "fixture-private-value" not in failure.stderr
    calls = scratch / "backup-calls"
    before = len(calls.read_text())
    original, rows = save("first")
    commands = [json.loads(line) for line in calls.read_text()[before:].splitlines()]
    assert sum(command[:2] == ["volume", "ls"] for command in commands) == 1
    assert "uncreated\twaiting\tmember-session:/session-state" in rows
    assert "volume\twaiting\tbot:/shared-inputs\tinputs\tshared-inputs" in rows
    assert f"file\tscout\tmember-session:/policy\tpolicy\t{scratch / 'policy'}" in rows
    assert "environment\tscout\tmember-session:/run/secrets/token\ttoken\tFIXTURE_TOKEN" in rows
    assert "fixture-private-value" not in rows
    assert f"bind\tscout\tbot:/home/node\t-\t{external_home}" in rows
    restore = (
        "restore_volume() ("
        + guide.split("restore_volume() (", 1)[1].split("\n)\n", 1)[0]
        + '\n)\nrestore_volume "scout-identity"'
    )
    result = subprocess.run(
        ["sh", "-eu"],
        input=restore,
        text=True,
        env={**deploy.env, "backup": str(original)},
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == 0, result
    recovered = stores / result.stdout.strip()
    assert (recovered / "identity").read_text() == "scout-identity"
    (recovered / "identity").write_text("after restore")
    (scout / "compose.override.yml").write_text(
        json.dumps({"volumes": {"identity": {"external": True, "name": recovered.name}}})
    )
    second, rows = save("second")
    assert f"volume\tscout\tmember-session:/session-state\tidentity\t{recovered.name}" in rows
    assert not (second / "volumes/scout-identity.tgz").exists()
    with tarfile.open(second / "volumes/restored-session.tgz") as saved:
        identity = saved.extractfile("./identity")
        assert identity is not None and identity.read() == b"after restore"
    running = deploy.call("backup-plan", "--files-only", "waiting", env={"RUNNING": "1"})
    assert running.stdout == rows
    for flag in ("STALE_MOUNT", "STALE_FILE"):
        stale = deploy.call("backup-plan", "--files-only", "waiting", env={flag: "1"}, ok=False)
        assert "DeploymentMountChanged" in stale.stderr and not stale.stdout
    # Registration can create session state and then fail before issuing a link.
    # An agent that never started gives no permission to skip that identity.
    session_volume = stores / "waiting-identity"
    session_volume.mkdir()
    assert "MemberAlreadyStarted" in deploy.call("backup-plan", "--files-only", "waiting", ok=False).stderr
    assert (
        "volume\twaiting\tmember-session:/session-state" in deploy.call("backup-plan", "--unstarted", "waiting").stdout
    )
    session_volume.rmdir()
    assert "MissingDeploymentVolume" in deploy.call("backup-plan", "--unstarted", "waiting", ok=False).stderr
    (waiting / "bot-link").write_text("issued")
    assert "MemberAlreadyStarted" in deploy.call("backup-plan", "--files-only", "waiting", ok=False).stderr
    (scout / "project-id").unlink()
    assert "BotProjectMissing" in deploy.call("backup-plan", ok=False).stderr
