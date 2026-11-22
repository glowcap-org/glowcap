"""The override example's bot block must work once uncommented.

No YAML library or Docker daemon is available to the host test, so this reads
the one block shape the example uses: nested mappings, lists of scalars, and
flow lists. A heading line `# == name ==` starts a piece, and the comment lines
after it are the piece. Uncommenting strips the `# ` after each line's
indentation, as the deployment guide tells an operator to.
"""

import re
from pathlib import Path

HEADING = re.compile(r"^\s*# == .+ ==$")
# Every setting `bot serve` reads from a variable: `FLAGS` in the bot's
# config.rs and the link flag. The installed tree this check reads holds no
# Rust source, so the list is kept here.
BOT_VARIABLES = {
    "HARNESS",
    "MODEL",
    "PERMISSION",
    "DEADLINE",
    "GLOWCAP",
    "ALLOW",
    "SENDER_LIMIT",
    "CONVERSATION_LIMIT",
    "STREAK_LIMIT",
    "INSTRUCTIONS",
    "LINK",
}


def uncomment(text, headings):
    """Uncomment the pieces whose heading names appear in `headings`."""
    out, active = [], False
    for line in text.splitlines():
        match = re.match(r"^\s*# == (.+) ==$", line)
        if match:
            active = match.group(1) in headings
            out.append(line)
        elif active and re.match(r"^\s*#( |$)", line) and not line.strip().startswith("# #"):
            out.append(re.sub(r"^(\s*)# ?", r"\1", line, count=1))
        else:
            active = active and re.match(r"^\s*#", line) is not None
            out.append(line)
    return "\n".join(out) + "\n"


def parse(text):
    """Parse nested mappings and scalar lists by indentation."""
    rows = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        assert indent % 2 == 0, f"line {number}: odd indentation: {raw!r}"
        rows.append((indent, line.strip(), number))

    def block(position, indent):
        if rows[position][1].startswith("- "):
            items = []
            while position < len(rows) and rows[position][0] == indent and rows[position][1].startswith("- "):
                items.append(scalar(rows[position][1][2:]))
                position += 1
            return items, position
        mapping = {}
        while position < len(rows) and rows[position][0] == indent:
            _, content, number = rows[position]
            assert not content.startswith("- "), f"line {number}: a list item among keys"
            key, _, rest = content.partition(":")
            assert key and re.fullmatch(r"[\w.${}/-]+", key), f"line {number}: not a key: {content!r}"
            assert key not in mapping, f"line {number}: duplicate key {key}"
            position += 1
            if rest.strip():
                mapping[key] = scalar(rest.strip())
            elif position < len(rows) and (
                rows[position][0] > indent or (rows[position][0] == indent and rows[position][1].startswith("- "))
            ):
                mapping[key], position = block(position, rows[position][0])
            else:
                mapping[key] = None
        assert position >= len(rows) or rows[position][0] < indent, f"line {rows[position][2]}: misplaced"
        return mapping, position

    def scalar(value):
        if value.startswith("["):
            assert value.endswith("]"), f"unclosed flow list {value!r}"
            return [item.strip().strip('"') for item in re.split(r",\s*(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)", value[1:-1])]
        return value.strip('"')

    tree, end = block(0, 0)
    assert end == len(rows), f"line {rows[end][2]}: could not place {rows[end][1]!r}"
    return tree


def bot_example(path):
    text = Path(path).read_text()
    assert "bot" not in parse(text).get("services", {}), "the bot is active in the example"
    assert "bot-session" not in parse(text).get("services", {}), "the bot session is active in the example"
    tree = parse(uncomment(text, {"bot session", "bot", "bot volumes", "bot secret"}))
    services, volumes, secrets = tree["services"], tree["volumes"], tree["secrets"]
    session, bot = services["bot-session"], services["bot"]
    assert session["entrypoint"][-3:] == ["rooms", "session", "serve"], session
    assert session["environment"]["GLOWCAP_ROOMS_SESSION_STATE"] == "/session-state"
    assert "glowcap-rooms-net" in session["networks"], "the bot session must reach the directory"
    assert session["healthcheck"]["test"][-3:] == ["session", "ready", "--file=/run/rooms-session/use.sturdyref"]
    assert bot["entrypoint"][-3:] == ["rooms", "bot", "serve"], bot
    assert bot["command"] == ["--dir=/bot-state"], bot
    assert bot["healthcheck"]["test"][-3:] == ["bot", "ready", "--dir=/bot-state"], bot["healthcheck"]
    assert bot["restart"] == "unless-stopped" and session["restart"] == "unless-stopped"
    assert bot["depends_on"]["bot-session"]["condition"] == "service_healthy"
    assert "networks" not in bot, "the bot needs none of the deployment's networks"
    variables = {name for name in bot["environment"] if name.startswith("GLOWCAP_ROOMS_BOT_")}
    assert variables and {name.removeprefix("GLOWCAP_ROOMS_BOT_") for name in variables} <= BOT_VARIABLES, variables
    named = set(re.findall(r"GLOWCAP_ROOMS_BOT_(\w+)", text))
    assert named <= BOT_VARIABLES, f"the example names variables serve does not read: {named - BOT_VARIABLES}"
    assert bot["environment"]["GLOWCAP_ROOMS_BOT_LINK"] == "/run/secrets/bot-link", "the link is read from its secret"
    assert bot["secrets"] == ["bot-link"] and secrets["bot-link"]["file"] == "./secrets/bot-link", secrets
    for service in (session, bot):
        for mount in service.get("volumes", []):
            source = mount.split(":", 1)[0]
            if not source.startswith(("$", ".", "/")):
                assert source in volumes, f"{source} is not declared"
    assert {v["name"] for v in volumes.values()} == {
        "glowcap-rooms-bot-session-state",
        "glowcap-rooms-bot-state",
        "glowcap-rooms-bot-home",
    }, volumes
    # The home is its own volume inside the bot directory, so removing the bot
    # state volume to start the bot fresh keeps what its agent saved.
    mounts = dict(reversed(mount.split(":")[:2]) for mount in bot["volumes"])
    assert mounts.get("/bot-state") == "bot-state" and mounts.get("/bot-state/home") == "bot-home", mounts
    assert bot["build"]["args"]["GLOWCAP_ROOMS_IMAGE"] == "glowcap-rooms:selected"
    # The example with nothing uncommented still holds its active services only.
    inert = parse(uncomment(text, set()))
    assert "bot" not in inert["services"] and "secrets" not in inert and "volumes" not in inert, inert
    return tree
