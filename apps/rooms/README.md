# Rooms

Rooms is a chat application built on glowcap. Everyone in a room is a peer:
a browser tab, a terminal, a program, a Spritely Goblins vat. Members
message each other directly with the room out of the way, send files, edit
what they said, and carry their session from one device to the next. There
are no accounts. A member holds references to the rooms and conversations it
is in, and holding a reference is what lets it act.

The [Rooms pages on the site](https://jimisaacs.github.io/glowcap/rooms/)
show what it is like to use. This page is for someone who has the repository
checked out and wants to run it, read it, or change it.

## Run it

From the repository root:

```sh
zig build rooms-web
```

That builds the services and the browser page and serves the page at
`http://localhost:8000`. Open it, choose to keep your session in this
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

It keeps its identity, room links, and capability swiss numbers under
`.local/.state/rooms`, so a restart brings back the same server.

## Other ways in

- **From a terminal, over iroh.** `glowcap app rooms-peer` is the presence
  client that ships with the CLI. [`docs/cli.md`](../../docs/cli.md) lists
  its flags.
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

Without flags, rooms and messages live in memory and a restart drops them.
Three services keep state across restarts, each with one state directory and
an identity that survives:

| Service | Keeps | Start |
| --- | --- | --- |
| `rooms-server` | The directory, its rooms, room links, and operator capabilities; with `--history`, each listed room's recent lines | `zig build rooms-server -- --state=<dir> --history` |
| `rooms-session` | One person's whole workspace, so several browsers can open the same session | `zig build rooms-session -- --state=<dir>` |
| `rooms-archive` | A member's own message history, behind a sturdyref | `zig build rooms-archive -- --state=<dir>` |

[Operating Rooms](operating.md) describes each one, the history limits, the
operator capabilities, and moderation. The
[deployment guide](web/deploy/README.md) runs all of them behind a reverse
proxy with Docker Compose.

## How it is built

Rooms is written in Rust, with the browser page in TypeScript and React. The
same Rust crates run as services and in the browser as WebAssembly, linked
with glowcap's Zig protocol core in one module, so joining, sending, and
recovering mean the same thing in both places.

| Path | Owns |
| --- | --- |
| [`rust/`](rust/) | The application crates, the services, and the browser Wasm adapter |
| [`web/ui/`](web/ui/) | The browser page |
| [`web/deploy/`](web/deploy/) | The Compose deployment and its operations front |
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

## Prerelease

Rooms ships from this repository at an exact Git commit. There is no
versioned package or application image yet, and no state migration: the
server, session, and archive stores accept their current schema and refuse
an older one rather than rewriting it. A release names its commit, its green
checks, and any state reset that commit requires.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../PROVENANCE.md).
