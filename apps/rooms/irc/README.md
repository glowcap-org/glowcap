# IRC on Rooms

This directory holds the two IRC edges of the rooms app. The bridge reads an
IRC channel as an ordinary Rooms room. The front lets an ordinary IRC client
enter rooms that live on a native Rooms directory. Both run over the same
CapTP machinery as every other Rooms client; IRC is a projection at the edge,
never a second protocol inside.

## The bridge: an IRC channel as a room

```sh
zig build rooms-irc-bridge
```

The default follows Libera's `#ocapn` over TLS and serves the resulting
`libera/#ocapn` room on a loopback CapTP listener. The command prints the
listener port and the room name; join them with any Rooms client. IRC members
appear as `irc/<nick>`, which keeps their origin visible on every front.

The default is read-only. A registered bridge nick can carry Rooms messages
back to IRC when its SASL password is available in
`PANCAKE_ROOMS_IRC_SASL_PASSWORD`:

```sh
zig build rooms-irc-bridge -- \
  --mode=two-way --sasl-account=YOUR_ACCOUNT --irc-nick=YOUR_REGISTERED_NICK
```

Two-way mode requires TLS. It sends Rooms lines as `<nick> text`, paces them
at one every 1.2 seconds, and retains at most 64 complete IRC lines (32 KiB)
across a reconnect. The bridge joins IRC when its first Rooms reader arrives
and parts after the last reader and queued line leave. Options after `--`
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
there is none.

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

The hermetic tests (`../test/irc_*_test.ts`) run inside
`zig build rooms-server-test`, which `zig build check` depends on; the front
scenario drives a real socket at the Goblins-compatible 1.0/Syrup floor and
proves channel traffic, metadata, and introduced direct messages in both
directions over Noise. `zig build goblins-rooms-irc` runs both edges against
a real Goblins vat: fixture IRC through the bridge both ways, ordinary IRC
through the front with channel traffic and an IRC-initiated direct message
the vat answers.

## Files

- `main.ts` / `config.ts`: the bridge entry and its flags.
- `bridge.ts` / `client.ts` / `registration.ts`: the IRC connection, SASL,
  and channel membership the bridge drives.
- `front_main.ts` / `front_config.ts` / `front.ts`: the front entry, its
  flags, and the per-connection projection onto a Directory session.
- `front/`: the front's inbox router, limits, and message rendering.
- `protocol.ts` / `outbound.ts` / `socket_writer.ts`: IRC line parsing,
  encoding, pacing, and the bounded write queue.
