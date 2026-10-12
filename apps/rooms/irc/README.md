# IRC on Rooms

The two IRC edges of Rooms are Rust executables. The bridge reads an
IRC channel as an ordinary Rooms room. The gateway lets an ordinary IRC client
enter rooms that live on a Rooms directory. Both run over the same
CapTP machinery as every other Rooms client. IRC is a projection at the edge,
not a second protocol inside.

## The bridge: an IRC channel as a room

```sh
zig build rooms-irc-bridge -- \
  --irc-realname="glowcap Rooms bridge bot; admin: YOUR_LIBERA_NICK"
```

The command builds and runs the `rooms-irc-bridge` executable.
`zig build rooms-irc-bridge-build` installs it without starting a service.
The default endpoint follows Libera's `#ocapn` over TLS and serves the resulting
`libera/#ocapn` room on a loopback CapTP listener. The command prints the
listener port and the room name. Join them with any Rooms client. IRC members
appear as `irc/<nick>`, which keeps their origin visible everywhere.

### Identifying the bot

Libera requires a bot to identify itself and a reachable administrator, either
through a bot cloak or through its public real-name field. The bridge requires
`--irc-realname` and always sends that value as the IRC real name (GECOS), even
when the account already has a cloak. Write text that clearly says this is a
bot and names an administrator who can be reached directly on Libera. The
bridge also turns on the IRCv3 bot user mode when the server advertises it.

### Before connecting to Libera

Read Libera's [bot policy](https://libera.chat/policies/#bots) first. The
bridge cannot check any of the following for you:

- An administrator must get channel-operator permission for every configured
  channel, including permission for the history the bridge makes visible in
  Rooms. The Operations join form records the operator's statement that
  permission was given before it admits a channel, but the bridge cannot get
  or verify that permission itself.
- A bridge administrator must be connected directly to Libera.
- Channel operators must tell IRC users before making history public, and
  should offer the unlogged-comment and removal options that Libera's
  public-logging policy describes.
- Libera does not allow its network to be used for bot-to-bot or other
  non-human communication without explicit staff permission. Interactive bots
  should be voiced where possible. Neither the real-name field nor bot mode
  grants either permission.

### LLM clients

Do not connect an LLM-enabled Rooms client to a Libera-backed room unless all
of these hold:

- the channel has explicitly opted in to that processing
- its topic or entry message discloses that an LLM is present
- a responsible human who consents is in the channel with it

Libera treats any LLM processing of channel content as public logging, and
requires generated content sent back to IRC to be labeled as such. The bridge
cannot detect or enforce any of this.

### The shared feed and personal connections

The shared feed is the deployment's automated bot and uses the configured bot
identity. A participant who chooses to speak on IRC opens a separate client
connection under their own nick and, optionally, their own account. That
connection is theirs, not another copy of the shared bot. Operators are still
responsible for confirming that this use, and each account, follows the
network's rules.

### Read-only and two-way modes

The bridge is read-only by default, and the room says so in terms every Rooms
client already understands. A read-only bridge seats each reader as an
observer, so the browser's composer shows the room is read-only before
anything is typed, rather than refusing a line afterwards.

In either mode, the room offers no file upload, because IRC cannot carry
files, and it says it keeps no link previews and relays no typing. The page
follows those statements: the attach control is hidden, a pasted or dropped
file gets an explanation in the log, no preview is offered, and the About tab
of the room's card says what messages there can carry.

A registered bridge nick can send Rooms messages back to IRC when its SASL
password is in `GLOWCAP_ROOMS_IRC_SASL_PASSWORD`:

```sh
zig build rooms-irc-bridge -- \
  --irc-realname="glowcap Rooms bridge bot; admin: YOUR_LIBERA_NICK" \
  --mode=two-way --sasl-account=YOUR_ACCOUNT --irc-nick=YOUR_REGISTERED_NICK
```

Two-way mode requires TLS. It sends Rooms lines as `<nick> text`, paces them
at one every 1.2 seconds, and retains at most 64 complete IRC lines (32 KiB)
across a reconnect. A post answers after its socket write succeeds. A write
with an uncertain outcome is refused instead of replayed. Shutdown refuses
every admitted line that did not reach the socket. The bridge joins IRC when its first Rooms reader arrives
and parts after the last reader and queued line leave. An operator-held
gateway keeps its network capabilities apart from its channel leases, and a
network with no channels owns no socket. Each channel publication has a
source-owned durable entry and a separately issued Rooms moderator capability
the Rooms directory cannot forge. Parting retires both live publications, and
recreating the channel receives a fresh generation. Bridge moderation removes
Rooms memberships and carries no IRC operator privilege.

Options after `--` choose another network, channel, nick, IRC endpoint, or
Rooms port. They are `--network`, `--channel`, `--irc-host`, `--irc-port`,
`--irc-nick`, `--irc-realname`, `--mode`, and `--sasl-account`, plus `--bind`,
`--announce-host`, `--port`, and `--tls`. Use `--tls=false` only against a private, read-only
test server.

## The gateway: an IRC client on Rooms

```sh
zig build rooms-irc-front -- --directory=127.0.0.1:9099
```

`--directory` takes the room server's locator in either form it prints: a
TCP `host:port`, or the `ocapn://…iroh` locator an iroh server announces on
its `ROOMS-SERVER-LISTENING` line and serves at the web server's `/locator`.
A bare iroh node id is resolved through discovery, the way the server
published it. A locator that carries direct addresses is dialed as written,
with no relay and no lookup.

Point the IRC client at `127.0.0.1:6667`, choose a nickname, and
`JOIN #general`. The gateway supports channel and direct `PRIVMSG`, `NAMES`,
`LIST`, `PART`, `PING`, `TOPIC`, and `WHOIS`. A nickname is fixed for the
connection: changing a name across several independently granted room
memberships has no atomic capability operation, so reconnect to claim another
one. `JOIN` enters an existing room and reports the directory's refusal when
there is none, and a connection holds one membership per room, the same rule
every Rooms member follows.

Each IRC connection holds the Directory, Room, and introduced direct-message
capabilities it acquired, so direct messages use the same introduction and
retargeting rules as every other Rooms client. The endpoint another member
redeems is Noise-sealed by default. The IRC client itself cannot retain a
capability, so the gateway remains the endpoint and makes no end-to-end claim
on its behalf. Files and overlong Rooms lines cannot be represented by IRC
and produce a notice rather than a partial message. Rooms nicknames outside
IRC's alphabet receive a connection-local `rooms-<hash>` alias that `WHOIS`
relates back to the Rooms name.

Cleartext IRC is accepted only on loopback. To expose the listener, provide a
TLS keypair and a dialable address for the Noise direct-message endpoint:

```sh
zig build rooms-irc-front -- \
  --directory=ROOMS_LOCATOR --bind=0.0.0.0 --port=6697 \
  --tls-cert=/run/rooms/fullchain.pem --tls-key=/run/rooms/private-key.pem \
  --dm-bind=0.0.0.0 --dm-announce-host=rooms.example
```

`--dm-transport=iroh` advertises an encrypted, endpoint-authenticated iroh
locator instead. That is the setup to deploy when a Goblins vat should be able
to dial in cold, through this repository's Goblins iroh netlayer.
`--dm-transport=tcp` is for local Goblins conformance testing, and it can only
bind to loopback.

## Bounds

The gateway admits at most 256 clients. One client holds at most 32 rooms and
32 direct lines, 256 live inbox publications, 2,048 projected nicknames, and
64 queued IRC writes totaling 32 KiB, so the shared Host ledger is bounded at
65,536 live inboxes. Disconnect retires aliases, and a reconnect does not
retarget an old capability.

## Evidence

The in-tree tests (`../test/irc/`) run inside
`zig build rooms-server-test`, which `zig build runtime-check` depends on. The gateway
scenario starts the installed Rust server and gateway and proves channel traffic,
metadata, and introduced direct messages in both directions over Noise. TLS
scenarios cover independent clients and rooms, sibling direct messages and
departure with Noise, TCP and iroh inboxes. A reconnect reuses its nickname
without reviving the previous connection's inbox. Native checks cover bounded
nickname ownership and asynchronous socket failures reaching the direct sender.
`zig build goblins-rooms-irc` runs both edges against
a real Goblins vat: fixture IRC through the bridge both ways, ordinary IRC
through the gateway with channel traffic and an IRC-initiated direct message
the vat answers.

## Files

The two edges point opposite ways, so each has its own directory and the
vocabulary they share stays between them.

- `../rust/services/src/irc_bridge/`: the standalone bridge executable
  adapter, configuration, capability serving and outbound ownership.
  `../rust/application/src/server/irc/` owns portable IRC policy.
  `../rust/services/src/irc/` owns sockets, TLS and serialized writes.
- `../rust/services/src/irc_front/`: the gateway's IRC listener, each client's
  capability ownership, room pumps and direct-message receipts. Portable
  naming and rendering policy lives in `../rust/application/src/server/irc/front/`.
- `protocol.ts`: the TypeScript test consumer's line parsing and encoding.
  Rust owns nickname and SASL admission plus the bounded write queue.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../../PROVENANCE.md).
