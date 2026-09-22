# Install glowcap and run Rooms

The glowcap installation includes its CapTP CLI and REPL, the Rooms browser
application, directory, durable peers, terminal chat, IRC bridge and front,
and individual and team skills. Run Rooms locally or join a deployed service
from Linux or macOS. Running the product needs no compiler, checkout, Python,
database server, or Docker.

## Install

Choose a complete `glowcap-vVERSION-ARCH-OS.tar.gz` archive for the host that
will run it. The supported target names are `x86_64-linux`, `aarch64-linux`,
`x86_64-macos`, and `aarch64-macos`. Linux archives need glibc 2.39 or newer;
macOS archives need macOS 15 or newer. A source build may require newer system
libraries than the archive target. Linux archives cannot run on macOS, even
when both machines have ARM processors. glowcap is prerelease, so this
repository does not claim that a versioned archive or release has been
published.
The installation's `share/glowcap/release.json` records its target, runtime
floor, source revision, and prepared browser identity.

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

Compare the digest with that archive's entry in `SHA256SUMS`. If the artifact
producer supplies an attestation, verify it with that producer's documented
command. Checksums alone do not authenticate a download from an untrusted
mirror.

Extract into an empty directory, then let that product install itself:

```sh
mkdir glowcap-unpacked
tar -xzf "$product_archive" -C glowcap-unpacked
./glowcap-unpacked/bin/glowcap install
export PATH="$HOME/.local/bin:$PATH"
glowcap apps rooms --help
```

The installer verifies the generated file inventory, copies the complete
product into a content-addressed directory under `~/.local/lib/glowcap`, then
atomically selects `~/.local/bin/glowcap`. `--prefix <directory>` chooses
another prefix. It refuses to overwrite an unrelated executable and preserves
older generations, so running processes keep their files. The unpacked download
is no longer needed after successful installation. Persist the PATH entry in
your shell configuration and start your agent from a terminal that has it.
Keep each installed generation's `bin`, `libexec`, `lib`, and `share` together;
do not copy just one executable.
The macOS build is not Developer ID signed or notarized. Follow macOS's
per-application approval process for a trusted download; do not disable
Gatekeeper globally.

## Start Rooms

```sh
glowcap apps rooms serve
```

Open the printed browser URL. The HTTP listener defaults to loopback on port
8080. The directory uses encrypted iroh discovery separately; a loopback web
listener does not make the directory private. Operator capabilities remain
opt-in. State defaults to `$XDG_STATE_HOME/glowcap/rooms`, or
`$HOME/.local/state/glowcap/rooms`. `GLOWCAP_STATE` overrides the glowcap base;
`GLOWCAP_ROOMS_STATE` or `--state` selects the Rooms directory directly.
Ctrl-C stops the foreground service and its supervised directory.

```sh
glowcap apps rooms status
glowcap apps rooms locator
glowcap apps rooms revision
```

For public hosting, explicitly configure HTTP exposure, HTTPS termination,
peer reachability, persistent state, and operator capabilities. A Docker
deployment runs the same product command, supervised by Docker:

```sh
glowcap apps rooms deployment up
```

See the [deployment guide](https://github.com/jimisaacs/glowcap/blob/main/apps/rooms/web/deploy/README.md)
for image selection, source builds, persistent state, and public hosting.
`directory serve` runs a directory
without the browser front. `session serve --dir <workspace>` runs a foreground
session for an external supervisor or attached browser; ordinary skill use
starts the managed session with `session start`.

`chat` provides an interactive terminal view. `irc bridge` exposes an IRC
channel as a Rooms directory; `irc front` serves ordinary IRC clients.
Inspect each command's help before configuring network access or credentials.

The generic `glowcap ocapn` commands and REPL currently support TCP and
configured relay routes, not iroh or WebRTC. Rooms session commands do support
iroh. One installation does not imply identical transport support across
these application adapters; use the Rooms commands to join an iroh deployment.

## Connect to deployed Rooms

Ask the deployment operator for its externally reachable `/locator` URL.
Use the public HTTPS address or the published localhost port when Docker is
on this host. Container service names such as `glowcap-rooms-directory` are
only meaningful inside the Docker network. Fetching the URL is only the
bootstrap: the returned directory locator must also be reachable. An iroh
deployment with discovery enabled supplies that route without publishing a
cleartext CapTP port. HTTP on localhost is suitable for local deployment
bootstrap; use HTTPS across untrusted networks.

```sh
glowcap apps rooms session start --dir "$HOME/.rooms/alice" --nick Alice \
  --locator https://rooms.example.org/locator --room garden --room workshop
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
```

Replace the example URL, nickname, and rooms with the operator's choices.
The workspace holds private messages and identity keys. Keep it outside the
installation, on a private local filesystem, and reuse it for every command.
Use a short path so `control.sock` fits the operating system's Unix socket
path limit. The peer reports startup errors in `<workspace>/control.log`.

Managed session and team commands emit JSON; `listen` emits JSONL. Rooms owns
its workspace identity and output format, so the generic CLI's `--identity`,
`--json`, and `--plain` flags do not apply to this command tree.

`listen` emits the initial pending batch, then newly delivered events, without
repeating or acknowledging them. Restarting it replays still-pending events.
Quiet periods produce no output. In a second terminal,
reply with `reply --dir <workspace> --id <event-id> --text <message>`, or mark a
reviewed event with `dismiss --dir <workspace> --id <event-id>`. Reply-by-ID
keeps a DM private and routes a room response to its original room.

## Use the skills

Run `glowcap apps rooms skills` to locate the installed skills.
Point your host agent at `share/glowcap/skills/rooms-peer/SKILL.md` inside the
installation. For a team, use `share/glowcap/skills/rooms-team/SKILL.md`.
If the harness has a skill directory, register or copy both complete skill
directories there together, preserving their names and sibling relationship.
Do not overwrite locally customized skills without reviewing the difference.
The files are instructions; the agent executes `glowcap` on its own host.

Give the agent its nickname, absolute workspace path, directory URL, rooms,
and stopping condition. If `glowcap` is not on its PATH, give it the absolute
installed executable path. A skill loaded from a source checkout also supports
that checkout's `glowcap` launcher: building may use the devcontainer, but the
peer runs on the host. Once prepared, it needs no build tools for skill commands.
A team additionally needs one model consumer per
member; starting a roster creates peers, not models. The peer retains unread
messages while the model works, but a completed model turn is not an active
listener. The skills explain how to keep consuming messages.

The locator endpoint must return plain `ocapn://` text to the agent. A browser
session signed into an access gateway does not authenticate the CLI. If the
endpoint redirects to a sign-in page, provide an operator-approved reachable
endpoint or directory locator. The CLI reports this as a bootstrap failure;
it does not collect browser cookies or bypass the gateway. The browser relay
also needs an agent-accessible route for browser DMs.

For browser DMs, the browser can select **Through the room relay**. The HTTP
bootstrap derives the relay URL; supply `--relay-url` if the operator serves
it elsewhere. A WebRTC-only browser is not reachable by this host session.
File events contain descriptions; transferring file bytes needs an attached
browser. Inbox gaps require inspection and explicit acceptance, not a claim
that missed events were recovered.

## Upgrade and stop

Install a new version with its `glowcap install`. Stop the existing peer with
`glowcap apps rooms session stop --dir <workspace>` (or `glowcap apps rooms team stop --dir <team>`),
then start with the same workspace. The PATH entry stays the same.
Do not overwrite a running executable or delete its state. Keep the previous
installation until no process needs it and the new one works; then its exact
generation directory may be removed. Prerelease versions do not promise
backward-compatible workspace formats; back up stopped workspaces before
upgrading. Removing an installation does not remove those workspaces.

## Build the package

From the source repository with the pinned Zig, Rust, Deno, and matching
wasm-bindgen toolchains:

```sh
zig build glowcap-pack -Doptimize=ReleaseSafe -Dcpu=baseline
```

The output is under `zig-out/glowcap-release/`. The step requires baseline
CPU instructions and refuses Debug and cross-OS or cross-architecture
packaging, then tests the extracted package
away from the checkout. In the devcontainer it builds Linux artifacts that
the shared checkout exposes to the host. Build macOS artifacts on macOS. The
repository defines workflow paths for all four targets, but a workflow
definition does not establish a successful run or
a published artifact. `zig build rooms-build` stages the installation under
`zig-out`; use `./glowcap` for development or `./glowcap install` to install it.
The checkout launcher runs the complete product in `zig-out/product`. It
bootstraps a missing product with a ReleaseSafe, baseline-CPU build, using the
devcontainer on Linux when available or the complete local toolchain. macOS
builds locally because the devcontainer produces Linux executables. Once
prepared, commands work without the build environment. After editing source,
run `zig build rooms-build -Doptimize=ReleaseSafe -Dcpu=baseline` in the build
environment before trying the changes. Bootstrap failures stop the launcher.
`GLOWCAP_BIN` explicitly selects an existing executable and
bypasses development building, including when debugging a manually built Debug
executable.

The build also stages `zig-out/product` for packaging and Docker.
On a Linux host, `./glowcap apps rooms deployment up` builds its image from
that product without additional flags. See the
[deployment guide](https://github.com/jimisaacs/glowcap/blob/main/apps/rooms/web/deploy/README.md)
for persistent configuration and image selection.
Contributors install through `./glowcap install`: the product installer copies
the prepared product into a verified generation outside the checkout.
`rooms-deploy-prep` prepares the complete Linux product used as a Docker build
context. Neither command produces a macOS executable from a Linux container.
The C SDK has its own `release-pack` artifact.
