# IRC on Rooms

The two IRC edges of the Rooms app run as native Rust executables. The bridge reads an
IRC channel as an ordinary Rooms room. The front lets an ordinary IRC client
enter rooms that live on a native Rooms directory. Both run over the same
CapTP machinery as every other Rooms client; IRC is a projection at the edge,
never a second protocol inside.

## The bridge: an IRC channel as a room

```sh
zig build rooms-irc-bridge
```

The command builds and runs the native Rust `rooms-irc-bridge` executable.
`zig build rooms-irc-bridge-build` installs it without starting a service.
The default follows Libera's `#ocapn` over TLS and serves the resulting
`libera/#ocapn` room on a loopback CapTP listener. The command prints the
listener port and the room name; join them with any Rooms client. IRC members
appear as `irc/<nick>`, which keeps their origin visible on every front.

The default is read-only. A registered bridge nick can carry Rooms messages
back to IRC when its SASL password is available in
`GLOWCAP_ROOMS_IRC_SASL_PASSWORD`:

```sh
zig build rooms-irc-bridge -- \
  --mode=two-way --sasl-account=YOUR_ACCOUNT --irc-nick=YOUR_REGISTERED_NICK
```

Two-way mode requires TLS. It sends Rooms lines as `<nick> text`, paces them
at one every 1.2 seconds, and retains at most 64 complete IRC lines (32 KiB)
across a reconnect. A post answers after its socket write succeeds; a write
with an uncertain outcome is refused instead of replayed. Shutdown refuses
every admitted line that did not reach the socket. The bridge joins IRC when its first Rooms reader arrives
and parts after the last reader and queued line leave. An operator-held
gateway keeps its network capabilities apart from its channel leases, and a
network with no channels owns no socket. Each channel publication has a
source-owned durable entry and a separately issued Rooms moderator capability
the native directory cannot forge; parting retires both live publications, and
recreating the channel receives a fresh generation. Bridge moderation removes
Rooms memberships and carries no IRC operator privilege. Options after `--`
choose another network, channel, nick, IRC endpoint, or Rooms port
(`--network --channel --irc-host --irc-port --irc-nick --mode --sasl-account
--bind --announce-host --port --tls`); use `--tls=false` only against a
private read-only test server.

## The front: an IRC client on native rooms

```sh
zig build rooms-irc-front -- --directory=127.0.0.1:9099
```

Point the IRC client at `127.0.0.1:6667`, choose a nickname, and
`JOIN #general`. The front supports channel and direct `PRIVMSG`, `NAMES`,
`LIST`, `PART`, `PING`, `TOPIC`, and `WHOIS`. A nickname is fixed for the
connection: changing a name across several independently granted room
memberships has no atomic capability operation, so reconnect to claim another
one. `JOIN` enters an existing room and reports the directory's refusal when
there is none, and a connection holds one membership per room, the same rule a
native member follows.

Each IRC connection holds the Directory, Room, and introduced direct-message
capabilities it acquired, so direct messages use the same introduction and
retargeting rules as every other Rooms client. The endpoint another member
redeems is Noise-sealed by default. The IRC client itself cannot retain a
capability, so the front remains the endpoint and makes no end-to-end claim
on its behalf. Files and overlong Rooms lines cannot be represented by IRC
and produce a notice rather than a partial message. Native nicknames outside
IRC's alphabet receive a connection-local `rooms-<hash>` alias that `WHOIS`
relates back to the native name.

Cleartext IRC is accepted only on loopback. To expose the listener, provide a
TLS keypair and a dialable address for the Noise direct-message endpoint:

```sh
zig build rooms-irc-front -- \
  --directory=ROOMS_LOCATOR --bind=0.0.0.0 --port=6697 \
  --tls-cert=/run/rooms/fullchain.pem --tls-key=/run/rooms/private-key.pem \
  --dm-bind=0.0.0.0 --dm-announce-host=rooms.example
```

`--dm-transport=iroh` instead advertises an encrypted,
endpoint-authenticated iroh locator, the deployment posture a Goblins vat can
cold-dial through this repository's Goblins iroh netlayer. `--dm-transport=tcp`
is the Goblins-compatible local conformance posture and is structurally
restricted to loopback.

## Bounds

The front admits at most 256 clients. One client holds at most 32 rooms and
32 direct lines, 256 live inbox publications, 2,048 projected nicknames, and
64 queued IRC writes totaling 32 KiB, so the shared Host ledger is bounded at
65,536 live inboxes. Disconnect retires aliases, and a reconnect never
retargets an old capability.

## Evidence

The in-tree tests (`../test/irc/`) run inside
`zig build rooms-server-test`, which `zig build check` depends on; the front
scenario starts the installed Rust server and front and proves channel traffic,
metadata, and introduced direct messages in both directions over Noise. TLS
scenarios cover independent clients and rooms, sibling direct messages and
departure with Noise, TCP and iroh inboxes. A reconnect reuses its nickname
without reviving the previous connection's inbox. Native checks cover bounded
nickname ownership and asynchronous socket failures reaching the direct sender.
`zig build goblins-rooms-irc` runs both edges against
a real Goblins vat: fixture IRC through the bridge both ways, ordinary IRC
through the front with channel traffic and an IRC-initiated direct message
the vat answers.

## Files

The two edges point opposite ways, so each has its own directory and the
vocabulary they share stays between them.

- `../rust/native/src/irc_bridge/`: the standalone bridge executable
  adapter, configuration, capability serving and outbound ownership.
  `../rust/application/src/server/irc/` owns portable IRC policy;
  `../rust/native/src/irc/` owns sockets, TLS and serialized writes.
- `../rust/native/src/irc_front/`: the native IRC listener, each client's
  capability ownership, room pumps and direct-message receipts. Portable
  spelling and rendering policy lives in `../rust/application/src/server/irc/front/`.
- `protocol.ts`: the TypeScript test consumer's line parsing and encoding.
  Rust owns nickname and SASL admission plus the bounded write queue.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../../PROVENANCE.md).
