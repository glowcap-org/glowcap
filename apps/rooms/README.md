# Rooms

Rooms is a chat application built on glowcap. Everyone in a room is a peer:
a browser tab, a terminal, a program, a Spritely Goblins vat. Members
message each other directly with the room out of the way, send files, edit
what they said, and carry their session from one device to the next. There
are no accounts. A member holds references to the rooms and conversations it
is in, and holding a reference is what lets it act.

The [Rooms pages on the site](https://jimisaacs.github.io/glowcap/rooms/)
show what it is like to use. The [host guide](host.md) explains installing
glowcap on Linux or macOS, running Rooms, and using the individual/team skills.

## Run it

With the complete glowcap installation on PATH:

```sh
glowcap apps rooms serve
```

Open the printed browser URL. The installation includes the prepared browser
application and its services, so startup needs no checkout or build tools.
Use `glowcap apps rooms session` to participate in an existing deployment and
`glowcap apps rooms team` to coordinate several such peers.

## Build and develop

From the repository root, `zig build rooms-build` stages that installation
under `zig-out/product`. For a contributor-run browser front:

```sh
zig build rooms-web
```

That builds the services and the browser page and serves the page at
`http://localhost:8080`. Open it, choose to keep your session in this
browser, pick a room name and a nickname, then open the same address in a
private window and join the same room as somebody else. Peers reach the
server over [iroh](https://www.iroh.computer/)'s encrypted QUIC, so the build
needs Zig, Cargo, and Deno.

Two other transports exist for particular situations:

```sh
zig build rooms-web -Dtransport=tcp     # cleartext loopback, for local testing
zig build rooms-web -Dtransport=onion   # a Tor onion service; needs tor
```

TCP proves nothing about who is on the other end and hides nothing, so use
it to look around or to reach a peer that speaks nothing else, never on a
network you do not trust. `-Dport=` pins the HTTP port, and server flags
such as `--history` or `--diagnostics` follow `--`.

For day-to-day development, start with every operator capability minted and
the state kept between runs:

```sh
zig build rooms-dev
```

Vite serves source modules with React Fast Refresh and proxies Rooms traffic to the
real web front. The browser still exercises the web relay, link
preview, ICE, and directory services. It keeps its identity, room links, and
capability swiss numbers under `.local/.state/rooms`, so a restart brings back
the same server. Ctrl-C retires both development processes.

Use `zig build rooms-dev -Dhot-reload=false` to serve compiled browser
generations through the web front with the same state and operator grants.
The [development guide](developing.md#browser-compiler-boundary) explains the
compiler boundary and how to switch bundlers.

## Other ways in

- **From a Linux or macOS host.** The [glowcap product package](host.md)
  includes `glowcap apps rooms session`, its runtime, and individual/team skills.
  Connect it to deployed Rooms without a checkout or compiler.
- **From a terminal, over TCP.** Start a cleartext server with
  `zig build rooms-server -- --transport=tcp --port=9099` and join it with
  `zig build rooms-chat -- 127.0.0.1:9099 general alice`. The client takes
  `/list`, `/open`, `/enter`, and `/leave`.
- **From five languages at once.** `zig build demo-rooms` starts a server and
  joins a Zig, Rust, Python, Racket, and Deno client to one room, checking
  that each member receives every message. `demo-rooms-iroh` and
  `demo-rooms-onion` run the same tour over encrypted QUIC and over Tor.
- **From a Goblins vat.** A [Spritely Goblins](https://spritely.institute/goblins/)
  vat sits in the same room on its own wire profile and can be messaged
  directly. [Bringing a Goblins vat into the room](goblins-vat.md) walks
  through it.
- **From IRC.** An IRC channel can be read as a room, and an ordinary IRC
  client can enter rooms. [IRC on Rooms](irc/README.md) covers both.

## Keeping things

`glowcap apps rooms serve` keeps its directory state outside the installation
by default. Message history is opt-in with `--history`. Standalone services
take explicit state directories; keep each service's identity and state together:

| Service | Keeps | Start |
| --- | --- | --- |
| Directory | The directory, its rooms, room links, and operator capabilities; with `--history`, each listed room's recent lines | `glowcap apps rooms directory serve --state=<dir> --history` |
| Session | One person's whole workspace, so several browsers can open the same session | `glowcap apps rooms session serve --dir=<dir>` |
| Archive | A member's own message history, behind a sturdyref | `glowcap apps rooms archive serve --state=<dir>` |

[Operating Rooms](operating.md) describes each one, the history limits, the
operator capabilities, and moderation. The
[deployment guide](web/deploy/README.md) runs them with Docker Compose and
explains how to add a reverse proxy or tunnel for public access.

## How it is built

Rooms is written in Rust, with the browser page in TypeScript and React. Vite
builds the production scripts and serves source modules during development.
Deno supplies its pinned runtime and lockfile. The same Rust crates run as
services and in the browser as WebAssembly, linked with glowcap's Zig protocol
core in one module, so joining, sending, and recovering mean the same thing in
both places.

| Path | Owns |
| --- | --- |
| [`rust/`](rust/) | The application crates, the services, and the browser Wasm adapter |
| [`web/ui/`](web/ui/) | The browser page |
| [`web/deploy/`](web/deploy/) | The Compose template and Linux image recipe used by the CLI deployment |
| [`lib/`](lib/) | The Rooms protocol as TypeScript, read by the Deno client, the demos, and the tests |
| [`clients/`](clients/) | One terminal client per language, each beside its generated protocol table |
| [`irc/`](irc/) | The IRC bridge and front |
| [`demos/`](demos/), [`test/`](test/) | The scripted scenarios and the checks |

The protocol itself is a handful of objects and the calls they answer. There
is no HTTP API and no schema negotiation: the server publishes one object by
name, `directory`, and every other reference is handed back from it.
[The Rooms protocol](https://jimisaacs.github.io/glowcap/rooms/protocol/)
lists each object; [Developing Rooms](developing.md) covers the build steps,
the scenarios, and the source map.
[What Rooms ships](shipped.md) describes each part of the implementation as
it stands.

## Prerelease

Rooms ships from this repository at an exact Git commit. There is no
published versioned package or application image yet. The server, session, and
archive stores accept their current schema and refuse an older one. A release names its commit, its green
checks, and any state reset that commit requires.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../PROVENANCE.md).
