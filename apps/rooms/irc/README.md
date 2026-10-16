# IRC on Rooms

Rooms connects to IRC in two directions, and each is a Rust executable. The
bridge shows an IRC channel as an ordinary Rooms room. The IRC server lets an
ordinary IRC client enter the rooms on a Rooms directory. Both talk to Rooms
over CapTP like any other client, so IRC is only how people see Rooms, not a
second protocol inside it.

## The bridge: an IRC channel as a room

```sh
zig build rooms-irc-bridge -- \
  --irc-realname="glowcap Rooms bridge bot; admin: YOUR_LIBERA_NICK"
```

The command builds and runs the `rooms-irc-bridge` executable.
`zig build rooms-irc-bridge-build` installs it without starting a service.
By default it follows Libera's `#ocapn` over TLS and offers a `libera/#ocapn`
room on a CapTP listener bound to the loopback address. The command prints the
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
  Rooms. The join form on the operations **IRC** page records the operator's statement that
  permission was given before it adds a channel, but the bridge cannot get
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
observer, so the browser's message box shows the room is read-only before
anything is typed, rather than refusing a line afterwards.

In either mode, the room offers no file upload, because IRC cannot carry
files, and it says it keeps no link previews and relays no typing. The page
follows those statements: the attach control is hidden, a pasted or dropped
file gets an explanation in the log, no preview is offered, and the **About** tab
of the room's card says what messages there can carry.

A registered bridge nick can send Rooms messages back to IRC when its SASL
password is in `GLOWCAP_ROOMS_IRC_SASL_PASSWORD`:

```sh
zig build rooms-irc-bridge -- \
  --irc-realname="glowcap Rooms bridge bot; admin: YOUR_LIBERA_NICK" \
  --mode=two-way --sasl-account=YOUR_ACCOUNT --irc-nick=YOUR_REGISTERED_NICK
```

Two-way mode requires TLS. It sends Rooms lines as `<nick> text`, paces them
at one every <!-- value ../rust/services/src/irc/feed.rs INTERVAL seconds -->1.2 seconds<!-- /value -->, and retains at most
<!-- value ../rust/services/src/irc_bridge/outbound.rs LINES -->64<!-- /value --> complete IRC lines across a reconnect.

- A post is confirmed only after its write to the socket succeeds. A write that
  may or may not have gone through is refused rather than sent again, and
  shutdown refuses every accepted line that never reached the socket.
- The bridge joins IRC when its first Rooms reader arrives and parts after the
  last reader and queued line leave.
- A network with no channels opens no socket.
- Each channel gets a durable directory entry and its own moderator
  capability, which the Rooms directory cannot forge. Leaving the channel
  retires both, and adding it again starts fresh.
- Bridge moderation removes Rooms memberships and carries no IRC operator
  privilege.

Options after `--` choose another network, channel, nick, IRC endpoint, or
Rooms port. They are `--network`, `--channel`, `--irc-host`, `--irc-port`,
`--irc-nick`, `--irc-realname`, `--mode`, and `--sasl-account`, plus `--bind`,
`--announce-host`, `--port`, and `--tls`. Use `--tls=false` only against a
private, read-only test server.

## The IRC server: an IRC client on Rooms

```sh
zig build rooms-irc-server -- --directory=127.0.0.1:9099
```

`--directory` takes the room server's locator in either form it prints: a
TCP `host:port`, or the `ocapn://…iroh` locator an iroh server announces on
its `ROOMS-SERVER-LISTENING` line and serves at the web server's `/locator`.
A bare iroh node id is resolved through discovery, the way the server
published it. A locator that carries direct addresses is dialed as written,
with no relay and no lookup.

Point the IRC client at `127.0.0.1:6667`, choose a nickname, and
`JOIN #general`. The server supports channel and direct `PRIVMSG`, `NAMES`,
`LIST`, `PART`, `PING`, `TOPIC`, and `WHOIS`. A nickname is fixed for the
connection, because each room granted its membership separately and nothing
can rename all of them at once. Reconnect to use another one.

A channel's topic is its room's subject description. `TOPIC` sets the subject
the way `/subject` does: a topic that starts with an `ocapn://` link links that
object and describes it with the words after it, and any other topic replaces
the subject with plain text.

`JOIN` enters an existing room and reports the directory's refusal when there
is none. A connection holds one membership per room, the same rule every Rooms
member follows.

Each IRC connection holds its own references to the directory, to its rooms,
and to the direct conversations it was introduced into, so direct messages
follow the same introduction rules as every other Rooms client. The connection
that other members dial is encrypted with Noise by default. An IRC client
cannot hold a reference itself, so the server is where that connection ends, and
nothing is encrypted end to end on the IRC client's behalf. Files and overlong Rooms lines cannot be represented by IRC
and produce a notice rather than a partial message. Rooms nicknames outside
IRC's alphabet get an alias like `rooms-<hash>` that exists only for that connection, and
`WHOIS` shows the real Rooms name.

Cleartext IRC is accepted only on loopback. To expose the listener, provide a
TLS keypair and a dialable address for the Noise direct-message endpoint:

```sh
zig build rooms-irc-server -- \
  --directory=ROOMS_LOCATOR --bind=0.0.0.0 --port=6697 \
  --tls-cert=/run/rooms/fullchain.pem --tls-key=/run/rooms/private-key.pem \
  --dm-bind=0.0.0.0 --dm-announce-host=rooms.example
```

`--dm-transport=iroh` advertises an encrypted, endpoint-authenticated iroh
locator instead. That is the setup to deploy when a Goblins vat should be able
to dial in with no earlier contact, through this repository's Goblins iroh netlayer.
`--dm-transport=tcp` is for local Goblins conformance testing, and it can only
bind to loopback.

## Bounds

The IRC server admits at most <!-- value ../rust/application/src/server/irc/clients.rs CLIENTS -->256<!-- /value --> clients. One client
holds at most <!-- value ../rust/application/src/server/irc/clients.rs ROOMS -->32<!-- /value --> rooms,
<!-- value ../rust/application/src/server/irc/clients.rs DIRECTS -->32<!-- /value --> direct lines,
<!-- value ../rust/application/src/direct/publication.rs DEFAULT_INBOX_LIMIT -->256<!-- /value --> live inbox
publications, <!-- value ../rust/application/src/server/irc/clients.rs PROJECTED_NAMES -->2,048<!-- /value --> Rooms nicknames shown to IRC, and
<!-- value ../rust/services/src/irc/socket.rs LINES -->64<!-- /value --> queued IRC writes totaling
<!-- value ../rust/services/src/irc/socket.rs BYTES bytes -->32 KiB<!-- /value -->. So the shared Host holds at most
clients times publications live inboxes. A disconnect retires that
connection's aliases, and a reconnect never reuses its old inbox.

## Tests

The in-tree tests (`../test/irc/`) run inside
`zig build rooms-server-test`, which `zig build runtime-check` depends on. The IRC server
scenario starts the installed room server and IRC server and checks channel traffic,
metadata, and introduced direct messages in both directions over Noise. TLS
scenarios cover separate clients and rooms, direct messages between two IRC
clients, and leaving, with Noise over both TCP and iroh inboxes. A reconnect reuses its nickname
without reviving the previous connection's inbox. Rust unit tests cover bounded
nickname ownership and asynchronous socket failures reaching the direct sender.
`zig build goblins-rooms-irc` runs both edges against
a real Goblins vat: fixture IRC through the bridge both ways, ordinary IRC
through the IRC server with channel traffic and an IRC-initiated direct message
the vat answers.

## Files

The two edges point opposite ways, so each has its own directory and the
vocabulary they share stays between them.

- `../rust/services/src/irc_bridge/`: the standalone bridge executable
  adapter, configuration, capability serving and outbound ownership.
  `../rust/application/src/server/irc/` owns portable IRC policy.
  `../rust/services/src/irc/` owns sockets, TLS and serialized writes.
- `../rust/services/src/irc_server/`: the IRC server's listener, each client's
  capability ownership, room pumps and direct-message receipts. Portable
  naming and rendering policy lives in `../rust/application/src/server/irc/clients/`.
- `protocol.ts`: the TypeScript test consumer's line parsing and encoding.
  Rust owns nickname and SASL admission plus the bounded write queue.

Project provenance and upstream-contact policy live in
[`PROVENANCE.md`](../../../PROVENANCE.md).
