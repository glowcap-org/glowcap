"""Protect the effective deployment's custody when Compose overrides names."""
import json


def selected_volumes(call, env, log, secret, password):
    env["CUSTOM_VOLUMES"] = "1"
    try:
        before = len(log.read_text())
        call("reset", "all", "--yes")
        calls = [json.loads(line) for line in log.read_text()[before:].splitlines()]
        assert [a[-1] for a in calls if a[:2] == ["volume", "rm"]] == [
            "custom-session", "custom-directory", "custom-postgres"]
        # Both the default and selected database exist. A lost custom secret
        # must refuse before any image change, stop, or deletion.
        secret.unlink()
        before = len(log.read_text())
        refused = call("up", ok=False)
        assert "MissingDatabaseSecret" in refused.stderr, refused.stderr
        calls = [json.loads(line) for line in log.read_text()[before:].splitlines()]
        assert not any(a[0] in ("build", "pull") or "down" in a or "up" in a for a in calls)
        secret.write_bytes(password)
        secret.chmod(0o600)
        for flag, reason in (("EXTERNAL_VOLUMES", "ExternalDeploymentVolume"),
                             ("BIND_VOLUME", "UnsupportedDeploymentMount"),
                             ("SHARED_VOLUME", "AmbiguousDeploymentVolume")):
            env[flag] = "1"
            try:
                before = len(log.read_text())
                refused = call("reset", "session", "--yes", ok=False)
                assert reason in refused.stderr, refused.stderr
                calls = [json.loads(line) for line in log.read_text()[before:].splitlines()]
                assert not any("down" in a or a[:2] == ["volume", "rm"] for a in calls)
            finally:
                del env[flag]
    finally:
        del env["CUSTOM_VOLUMES"]
