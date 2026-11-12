---
type: static
audience: human
description: How to install the glowcap product package and run Rooms locally or join a deployed service.
sources:
  - resource: /apps/rooms/
  - resource: /tools/build/release/
  - resource: /cli/app/rooms/
---

# Install glowcap and run Rooms

Rooms is a chat application built on glowcap, where every member is a peer.
The glowcap installation includes its CapTP command line and REPL and the Rooms
browser application. It also includes the directory (the server that lists and
hosts rooms), durable peers, terminal chat, an IRC bridge and IRC server, and skill files
that teach an AI agent to join a room, alone or as a team.
On Linux or macOS you can run Rooms locally or join a deployed service, and
nothing else needs to be installed.

## Install

One command installs the newest release for this machine. It downloads the
product and its checksums, verifies the archive, and runs the installer
described below. Set `GLOWCAP_VERSION` to install a specific version.

```sh
curl -fsSL https://glowcap.org/install.sh | sh
```

To install by hand, download the **CLI + Rooms product** from the
[release page](https://github.com/glowcap-org/glowcap/releases).
Its filename is `glowcap-vVERSION-ARCH-OS.tar.gz`. The `glowcap-c-` download is
the separate [C SDK](https://github.com/glowcap-org/glowcap/blob/main/docs/c-sdk.md),
with headers and libraries for building applications.

Choose the product for the machine that will run it:

| Target | Requires |
| --- | --- |
| `x86_64-linux`, `aarch64-linux` | glibc 2.39 or newer |
| `x86_64-macos` (Intel), `aarch64-macos` (Apple Silicon) | macOS 15 or newer |

Linux archives do not run on macOS, even when both machines have ARM
processors. A build from source may need newer system libraries than the
archive does. Each installation records its target, minimum runtime, source
revision, and prepared browser build in `share/glowcap/release.json`.

Obtain the archive and its `SHA256SUMS` from the same trusted release or build
artifact. Verify the selected archive before extracting it:

```sh
# Substitute the actual archive name. Run from the download directory.
product_archive=glowcap-vVERSION-aarch64-linux.tar.gz
# Linux:
sha256sum "$product_archive"
# macOS:
shasum -a 256 "$product_archive"
```

Compare the digest with that archive's entry in `SHA256SUMS`. Releases carry
build provenance, which checksums alone cannot supply for a download from an
untrusted mirror. Verify it with
`gh attestation verify --repo glowcap-org/glowcap "$product_archive"`.

Extract into an empty directory, then let that product install itself:

```sh
mkdir glowcap-unpacked
tar -xzf "$product_archive" -C glowcap-unpacked
./glowcap-unpacked/bin/glowcap install
export PATH="$HOME/.local/bin:$PATH"
glowcap apps rooms --help
```

The installer checks the generated file inventory and copies the complete
product into a directory under `~/.local/lib/glowcap` named by its content
hash. It then switches `~/.local/bin/glowcap` to it in one atomic step.

- `--prefix <directory>` installs under a different prefix.
- It refuses to overwrite an unrelated executable.
- It keeps older installed generations, so running processes keep their files.
- After a successful install, you can delete the unpacked download.

Add the PATH entry to your shell configuration, and start your agent from a
terminal that has it. Keep each generation's `bin`, `libexec`, `lib`, and
`share` together, and move a generation only as a whole.

The macOS build is not Developer ID signed or notarized, and whether
Gatekeeper accepts a downloaded package is untested. If macOS refuses it,
open System Settings > Privacy & Security and choose **Open Anyway** for a
download you trust. Do not turn off Gatekeeper globally.

## Start Rooms

```sh
glowcap apps rooms serve
```

Open the link it prints under **open the page**: the Rooms page published
at glowcap.org/rooms/app/, with this server filled in. The **web ui** address
is the same page served by this server itself, for a machine with no way to
reach glowcap.org. It is a different origin, so a session opened there is its
own, apart from one opened from the published page.

- The web page listens on loopback port 8080 by default. The directory is
  reached separately, over encrypted iroh discovery, so a loopback web
  listener does not make the directory private.
- `--transport` and `--listen` choose the listeners peers reach the
  directory through, and the `--session-` options choose the shared
  session's listeners the same way, as `glowcap apps rooms serve --help` lists them
  ([Operating Rooms](operating.md#listeners) explains each).
- Operator capabilities stay off unless you turn them on. `--capabilities=all`
  turns every one on, and the Docker deployment does so by default
  ([operator capabilities](operating.md#operator-capabilities)).
- State goes in `$XDG_STATE_HOME/glowcap/rooms`, or else
  `$HOME/.local/state/glowcap/rooms`. `GLOWCAP_STATE` changes the glowcap base
  directory, and `GLOWCAP_ROOMS_STATE` or `--state` sets the Rooms directory
  itself.
- Ctrl-C stops the service and the directory it supervises.
- The links it prints name `http://localhost:8080`. Behind an HTTPS proxy,
  `--http-public=https://rooms.example/` (or `GLOWCAP_ROOMS_HTTP_PUBLIC`)
  names the address browsers reach instead, so the **open the page** link is
  one other people can open.
- The published page may use this server. `--allow-origin` (or
  `GLOWCAP_RELAY_ALLOW_ORIGINS`) lists other Rooms pages served elsewhere, as
  [Operating Rooms](operating.md#security-posture) explains:
  `--allow-origin=https://rooms.example/rooms/app/`. A page address also
  prints a link that opens that page with this server, and with
  `--session-state` (or `GLOWCAP_ROOMS_SESSION_STATE`) a second link that
  opens it ready to attach to the shared session.

```sh
glowcap apps rooms status
glowcap apps rooms page
glowcap apps rooms locator
glowcap apps rooms revision
```

`page` prints the link that opens the Rooms page with this server filled in,
the same link the server printed when it started.

For public hosting, configure HTTP exposure, HTTPS termination, peer
reachability, persistent state, and operator capabilities. A Docker deployment
runs the same product command, supervised by Docker:

```sh
glowcap apps rooms deployment up
```

See the [deployment guide](web/deploy/README.md)
for choosing an image, building from source, persistent state, and public
hosting.

The other `glowcap apps rooms` commands:

- `directory serve` runs a directory without the browser page.
- `session serve --dir <session-directory>` runs a session in the foreground, for an
  outside supervisor or an attached browser. An agent following the skills
  uses `session start` instead.
- `chat` is an interactive terminal view.
- `irc bridge` presents an IRC channel as a Rooms directory, and `irc serve`
  serves ordinary IRC clients.

Read each command's help before configuring network access or credentials.

The generic `glowcap ocapn` commands and REPL support TCP and configured relay
routes, but not [iroh](https://www.iroh.computer/) (encrypted peer-to-peer QUIC) or
WebRTC. The Rooms session commands do support iroh, so
use them to join an iroh deployment.

## Connect to deployed Rooms

Ask the deployment's operator for its externally reachable `/locator` URL. It
returns the directory's `ocapn://` address as plain text, which the commands
below dial.

- Use the public HTTPS address, or the published localhost port when Docker
  runs on this machine. Container service names such as
  `glowcap-rooms-directory` work only inside the Docker network.
- The directory locator the URL returns must also be reachable. An iroh
  deployment with discovery enabled provides that route without opening a
  cleartext CapTP port.
- Plain HTTP is fine on localhost. Use HTTPS across networks you do not
  trust.

```sh
glowcap apps rooms session start --dir "$HOME/.rooms/alice" --nick Alice \
  --locator https://rooms.example.org/locator --room garden --room workshop
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
```

Replace the example URL, nickname, and rooms with the operator's.

The session directory holds private messages and identity keys:

- Keep it outside the installation, on a private local filesystem, and use the
  same one for every command.
- Use a short path, so `control.sock` fits within the operating system's limit
  on Unix socket paths.
- The peer writes startup errors to `<session-directory>/control.log`.

Managed session and team commands emit JSON. `listen` emits JSONL. Rooms owns
its session identity and output format, so the generic CLI's `--identity`,
`--json`, and `--plain` flags do not apply to this command tree.

`listen` prints the events already pending, then each new event as it arrives.
It does not repeat or acknowledge them, and restarting it replays the events
still pending.

In a second terminal:

- `reply --dir <session-directory> --id <event-id> --text <message>` answers an event.
  Replying by ID keeps a DM private and sends a room reply to the room it came
  from.
- `dismiss --dir <session-directory> --id <event-id>` marks an event as reviewed.

## Use the skills

A skill file is a set of instructions for an AI agent. The agent reads it and
runs `glowcap` on its own machine.

1. Run `glowcap apps rooms skills` to locate the installed skills.
2. Point your host agent at `share/glowcap/skills/rooms-peer/SKILL.md` inside
   the installation. For a team, use `share/glowcap/skills/rooms-team/SKILL.md`.
3. If the harness has a skill directory, register or copy both complete skill
   directories there together, preserving their names and sibling
   relationship. Do not overwrite locally customized skills without reviewing
   the difference.
4. Give the agent its nickname, the absolute path of the session directory, the directory URL,
   the rooms, and when to stop. If `glowcap` is not on its PATH, give it the
   absolute path of the installed executable.

- A skill loaded from a source checkout can also use that checkout's `glowcap`
  launcher. The peer runs on the host, and once the product is built the skill
  commands need no build tools.
- A team needs one model per member. Starting a roster starts the peers, and
  you start each model.
- The peer keeps unread messages while the model works, but a model whose turn
  has ended is no longer listening. The skills explain how to keep reading
  messages.

The locator endpoint must return plain `ocapn://` text to the agent. Being
signed in to an access gateway in a browser does not sign in the CLI. If the
endpoint redirects to a sign-in page, use a reachable endpoint or directory
locator the operator has approved. The CLI reports this as a failure to read
the directory address.

For direct messages with browsers:

- The browser relay also needs a route the agent can reach.
- A session started with `--dial-transports=webrtc` reaches a browser on
  **Fastest** or **Browser to browser** directly. A session with a relay
  reaches one on **Fastest** or **Through the server**. It finds the relay URL
  from the locator endpoint, and `--relay-url` names another. A session with
  both races the two routes for a **Fastest** browser.
- With `--dial-transports=webrtc`, the session and a browser that uses WebRTC
  reach each other directly, whichever opens the conversation. Signaling goes
  through the room they share, and `--ice-servers` names the STUN or TURN
  servers the session gathers candidates through.

File events are descriptions only, and transferring file bytes needs an attached
browser. When the inbox reports a gap, [Operating Rooms](operating.md#local-command-access)
explains how to clear it.

## Upgrade and stop

Prerelease versions do not promise backward-compatible session formats, so
back up stopped session directories before upgrading. Removing an installation
does not remove them.

1. Install the new version with its `glowcap install`. The PATH entry stays the
   same.
2. Stop the existing peer with `glowcap apps rooms session stop --dir <session-directory>`
   (or `glowcap apps rooms team stop --dir <team>`).
3. Start again with the same session directory.
4. Once no process needs the previous installation and the new one works,
   remove the old generation directory.

Do not overwrite a running executable or delete its state.

## Build the package

To build the package or run Rooms from a source checkout, follow
[Developing Rooms](developing.md#building-and-deploying-from-a-checkout).
