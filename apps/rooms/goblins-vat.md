# Bringing a Spritely Goblins vat into the room

Every Rooms peer the [development guide](developing.md) describes is a glowcap peer, and a room of glowcap peers uses
glowcap's own wire profile. A [Spritely Goblins](https://spritely.institute/goblins/) vat speaks the OCapN v1.0
baseline instead, and it can join the same room: each connection settles its own profile from what the two ends offer,
so the Goblins member arrives on the baseline while the glowcap members keep talking to each other on the native one.

Watching that happen takes three terminals and a browser.

Start the browser UI with the live timeline switched on. The shortest walkthrough uses the cleartext TCP testing adapter
and needs no transport sidecar. The repository also supplies the iroh netlayer used by the automated encrypted scenario;
it is an adapter for Goblins rather than a transport shipped by Goblins itself. The TCP Rooms server listens on port
9099:

```sh
zig build rooms-web -Dtransport=tcp -- --trace
```

Open `http://localhost:8000`, enter the room `general`, and pick a nickname. That is your glowcap member.

In a second terminal, start the viewer, switch the top bar to **Live**, and give the Source field the
`ROOMS-TRACE-LISTENING` sturdyref:

```sh
zig build ocapnviz-dev
```

In a third terminal, join the same room as a real Goblins vat and start typing:

```sh
racket -y conformance/goblins-peer/racket/rooms-chat.rkt \
  127.0.0.1:9099 general goblins-carol 9200
```

This is a chat terminal like `zig build rooms-chat`, except that the peer on the other end of it is a Goblins vat rather
than a glowcap one. It takes the same commands — `/list`, `/open <name>`, `/enter <name>`, `/leave`, `/help` — and
Ctrl-D quits. Anything else you type is a line in the room. The trailing `9200` is the port the vat's own netlayer
binds, which is where other members reach it privately.

What you type appears in the browser, what the browser types appears here, and on the viewer's stage the new session is
labeled `goblins-carol` and drawn on `syrup/v1_0` while yours stays on `capnp/next`: one room, two implementations, each
connection on the profile its own two ends could agree on.

`zig build goblins-rooms` runs the same meeting without the browser and checks it: a scripted Goblins vat and a glowcap
client exchange lines in one room, and the server's own trace has to show the two profiles. The scripted member is
`conformance/goblins-peer/racket/rooms-member.rkt`, next door to the interactive one.

## Direct-messaging the vat

Click the vat's name in the member pane and type. The room introduces you and then carries none of it: the line runs
between your browser and the vat, and the viewer draws it as a session of its own that disappears when you close the
thread. The vat prints it as `(dm) <you>`, and anything it types back with `/dm` comes home over the connection your
message arrived on.

Over cleartext TCP this needs one thing from the server. The browser reaches everything through the relay, and the relay
will not open a cleartext socket to an address a page named, so start the server with the vat's own address listed:

```sh
GLOWCAP_RELAY_TCP_PEERS=127.0.0.1:9200 zig build rooms-web -Dtransport=tcp
```

Over iroh there is nothing to list: an iroh destination has to be a peer holding the key it is named by, and the relay
dials any of them. `zig build goblins-rooms-dm` and `zig build goblins-rooms-dm-iroh` run the whole conversation, one
arm each, and check that it reaches the timeline and leaves it again.
