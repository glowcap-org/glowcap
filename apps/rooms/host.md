# Install glowcap and run Rooms

The glowcap installation includes its CapTP CLI and REPL, the Rooms browser
application, directory, durable peers, terminal chat, IRC bridge and front,
and individual and team skills. Run Rooms locally or join a deployed service
from Linux or macOS. Running the product needs no compiler, checkout, Python,
database server, or Docker.

## Install

Choose the complete `glowcap-vVERSION-ARCH-OS.tar.gz` archive for the machine
that will run it:

| Target | Requires |
| --- | --- |
| `x86_64-linux`, `aarch64-linux` | glibc 2.39 or newer |
| `x86_64-macos`, `aarch64-macos` | macOS 15 or newer |

Linux archives do not run on macOS, even when both machines have ARM
processors. A build from source may need newer system libraries than the
archive does. glowcap has no release yet, so this repository does not claim
that any versioned archive has been published.

Each installation records its target, minimum runtime, source revision, and
prepared browser build in `share/glowcap/release.json`.

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

The installer checks the generated file inventory and copies the complete
product into a directory under `~/.local/lib/glowcap` named by its content
hash. It then switches `~/.local/bin/glowcap` to it in one atomic step.

- `--prefix <directory>` installs under a different prefix.
- It refuses to overwrite an unrelated executable.
- It keeps older installed generations, so running processes keep their files.
- After a successful install, you can delete the unpacked download.

Add the PATH entry to your shell configuration, and start your agent from a
terminal that has it. Keep each generation's `bin`, `libexec`, `lib`, and
`share` together; do not copy a single executable out.

The macOS build is not Developer ID signed or notarized. Approve the
application through macOS's per-application process for a download you trust;
do not turn off Gatekeeper globally.

## Start Rooms

```sh
glowcap apps rooms serve
```

Open the printed browser URL.

- The web page listens on loopback port 8080 by default. The directory is
  reached separately, over encrypted iroh discovery, so a loopback web
  listener does not make the directory private.
- Operator capabilities stay off unless you turn them on.
- State goes in `$XDG_STATE_HOME/glowcap/rooms`, or else
  `$HOME/.local/state/glowcap/rooms`. `GLOWCAP_STATE` changes the glowcap base
  directory, and `GLOWCAP_ROOMS_STATE` or `--state` sets the Rooms directory
  itself.
- Ctrl-C stops the service and the directory it supervises.

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
for choosing an image, building from source, persistent state, and public
hosting.

The other `glowcap apps rooms` commands:

- `directory serve` runs a directory without the browser front.
- `session serve --dir <workspace>` runs a session in the foreground, for an
  outside supervisor or an attached browser. Ordinary skill use starts the
  managed session with `session start` instead.
- `chat` is an interactive terminal view.
- `irc bridge` presents an IRC channel as a Rooms directory, and `irc front`
  serves ordinary IRC clients.

Read each command's help before configuring network access or credentials.

The generic `glowcap ocapn` commands and REPL support TCP and configured relay
routes, but not iroh or WebRTC. The Rooms session commands do support iroh, so
use them to join an iroh deployment.

## Connect to deployed Rooms

Ask the deployment's operator for its externally reachable `/locator` URL.

- Use the public HTTPS address, or the published localhost port when Docker
  runs on this machine. Container service names such as
  `glowcap-rooms-directory` work only inside the Docker network.
- Fetching the URL is only the first step: the directory locator it returns
  must also be reachable. An iroh deployment with discovery enabled provides
  that route without opening a cleartext CapTP port.
- Plain HTTP is fine on localhost. Use HTTPS across networks you do not
  trust.

```sh
glowcap apps rooms session start --dir "$HOME/.rooms/alice" --nick Alice \
  --locator https://rooms.example.org/locator --room garden --room workshop
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
```

Replace the example URL, nickname, and rooms with the operator's.

The workspace directory holds private messages and identity keys:

- Keep it outside the installation, on a private local filesystem, and use the
  same one for every command.
- Use a short path, so `control.sock` fits within the operating system's limit
  on Unix socket paths.
- The peer writes startup errors to `<workspace>/control.log`.

Managed session and team commands emit JSON; `listen` emits JSONL. Rooms owns
its workspace identity and output format, so the generic CLI's `--identity`,
`--json`, and `--plain` flags do not apply to this command tree.

`listen` first prints the events already pending, then each new event as it
arrives. It never repeats or acknowledges them, and it prints nothing while
things are quiet. Restarting it replays the events still pending.

In a second terminal:

- `reply --dir <workspace> --id <event-id> --text <message>` answers an event.
  Replying by ID keeps a DM private and sends a room reply to the room it came
  from.
- `dismiss --dir <workspace> --id <event-id>` marks an event as reviewed.

## Use the skills

Run `glowcap apps rooms skills` to locate the installed skills.
Point your host agent at `share/glowcap/skills/rooms-peer/SKILL.md` inside the
installation. For a team, use `share/glowcap/skills/rooms-team/SKILL.md`.
If the harness has a skill directory, register or copy both complete skill
directories there together, preserving their names and sibling relationship.
Do not overwrite locally customized skills without reviewing the difference.
The files are instructions; the agent executes `glowcap` on its own host.

Give the agent its nickname, the absolute workspace path, the directory URL,
the rooms, and when to stop. If `glowcap` is not on its PATH, give it the
absolute path of the installed executable.

- A skill loaded from a source checkout can also use that checkout's
  `glowcap` launcher. Building may use the devcontainer, but the peer runs on
  the host, and once the product is built the skill commands need no build
  tools.
- A team needs one model per member. Starting a roster creates peers, not
  models.
- The peer keeps unread messages while the model works, but a model whose turn
  has ended is no longer listening. The skills explain how to keep reading
  messages.

The locator endpoint must return plain `ocapn://` text to the agent. Being
signed in to an access gateway in a browser does not sign in the CLI. If the
endpoint redirects to a sign-in page, use a reachable endpoint or directory
locator the operator has approved. The CLI reports this as a bootstrap
failure; it never collects browser cookies or gets around the gateway.

For direct messages with browsers:

- The browser relay also needs a route the agent can reach.
- In the browser, choose **Through the room relay**. The HTTP bootstrap works
  out the relay URL; pass `--relay-url` if the operator serves it somewhere
  else.
- A browser that uses only WebRTC cannot be reached from this host session.

File events are descriptions only; transferring file bytes needs an attached
browser. When the inbox reports a gap, inspect it and accept it explicitly.
Accepting a gap does not recover the missed events.

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

The output goes under `zig-out/glowcap-release/`.

- The step requires baseline CPU instructions. It refuses Debug builds and
  refuses to package for another OS or architecture.
- It tests the extracted package away from the checkout.
- In the devcontainer it builds Linux artifacts, which the shared checkout
  makes visible to the host. Build macOS artifacts on macOS.
- The repository defines workflows for all four targets. A workflow
  definition does not mean a run succeeded or an artifact was published.

### Running from a checkout

`zig build rooms-build` stages the installation under `zig-out`. Use
`./glowcap` to run it during development, or `./glowcap install` to install it.

- The checkout launcher runs the complete product in `zig-out/product`.
- If the product is missing, the launcher builds it first (ReleaseSafe,
  baseline CPU), using the devcontainer on Linux when available, or else the
  full local toolchain. macOS always builds locally, because the devcontainer
  produces Linux executables. If that build fails, the launcher stops.
- Once the product is built, commands work without the build environment.
- After editing source, run
  `zig build rooms-build -Doptimize=ReleaseSafe -Dcpu=baseline` in the build
  environment before trying your changes.
- `GLOWCAP_BIN` selects an existing executable and skips the development
  build, for example to debug a Debug executable you built by hand.

### Installing and deploying from a checkout

- `./glowcap install` copies the prepared product into a verified generation
  outside the checkout.
- On a Linux host, `./glowcap apps rooms deployment up` builds its Docker image
  from `zig-out/product` with no extra flags. The
  [deployment guide](https://github.com/jimisaacs/glowcap/blob/main/apps/rooms/web/deploy/README.md)
  covers persistent configuration and choosing an image.
- `rooms-deploy-prep` prepares the complete Linux product used as the Docker
  build context.
- Neither command can produce a macOS executable from a Linux container.

The C SDK is packaged separately, by `release-pack`.
