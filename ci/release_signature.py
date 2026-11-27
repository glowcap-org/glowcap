"""The release tag binds its name and commit to a repository administrator's GitHub SSH signing key.

The local release front checks the authenticated account before pushing. The
hosted workflows resolve the tagger on the immutable Git object. Both verify
the signed payload against the account's published keys in Git's SSH namespace.
"""

import json
import subprocess
import tempfile
from pathlib import Path


def github(*args):
    return json.loads(subprocess.check_output(["gh", "api", *args], timeout=60))


def github_rows(endpoint):
    output = subprocess.check_output(["gh", "api", endpoint, "--paginate", "--jq", ".[] | @json"], timeout=60)
    return [json.loads(line) for line in output.splitlines()]


def tagger_login(repository, oid):
    owner, name = repository.split("/")
    query = """query($owner:String!, $name:String!, $oid:GitObjectID!) {
      repository(owner:$owner, name:$name) { object(oid:$oid) { ... on Tag { tagger { user { login } } } } }
    }"""
    result = github("graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"oid={oid}")
    tagger = result["data"]["repository"]["object"]["tagger"]
    account = (tagger or {}).get("user")
    if not account:
        raise ValueError("GitHub could not identify the release tagger")
    return account["login"]


def local_login(tagger_email):
    account = github("user")
    login = account["login"]
    if tagger_email.lower() == f"{account['id']}+{login}@users.noreply.github.com".lower():
        return login
    emails = github_rows("user/emails?per_page=100")
    if any(row["verified"] and row["email"].lower() == tagger_email.lower() for row in emails):
        return login
    raise ValueError("configure the tagger email to a verified address of the authenticated GitHub account")


def verify(repository, login, tag, commit, payload, signature):
    if not payload.startswith(f"object {commit}\ntype commit\ntag {tag}\n".encode()):
        raise ValueError(f"the signed annotation must name {tag} and point directly to {commit}")
    if github(f"repos/{repository}/collaborators/{login}/permission")["permission"] != "admin":
        raise ValueError("the release tag signer must be a repository administrator")
    keys = github_rows(f"users/{login}/ssh_signing_keys?per_page=100")
    with tempfile.TemporaryDirectory() as temp:
        allowed = Path(temp) / "allowed_signers"
        allowed.write_text("".join(f"release {key['key']}\n" for key in keys))
        sig = Path(temp) / "tag.sig"
        sig.write_bytes(signature)
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", "release", "-n", "git", "-s", str(sig)],
            input=payload,
            capture_output=True,
            timeout=30,
        )
    if result.returncode:
        raise ValueError(f"{tag} needs a Git SSH signature from a signing key registered to the release administrator")


def verify_local(repository, tag, commit, raw):
    payload, marker, signature = raw.rpartition(b"-----BEGIN SSH SIGNATURE-----\n")
    if not marker or not payload.endswith(b"\n"):
        raise ValueError(f"{tag} needs an SSH-signed annotation")
    # Git quotes neither '<' nor '>' inside an ident. Ignore any message lines.
    headers = payload.partition(b"\n\n")[0].splitlines()
    if len(headers) != 4 or not headers[-1].startswith(b"tagger "):
        raise ValueError(f"invalid tagger in {tag}")
    email = headers[-1].rpartition(b"<")[2].partition(b">")[0].decode()
    verify(repository, local_login(email), tag, commit, payload, marker + signature)
