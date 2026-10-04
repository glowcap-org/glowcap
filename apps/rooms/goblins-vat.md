# Bringing a Spritely Goblins vat into the room

A [Spritely Goblins](https://spritely.institute/goblins/) vat can join the same Rooms room as glowcap peers. The
peers in the [development guide](developing.md) are all glowcap, and they talk to each other on glowcap's own wire
profile. A Goblins vat speaks the OCapN v1.0 baseline instead. Each connection settles its own profile from what its two
ends offer, so the Goblins member uses the baseline while the glowcap members keep using the native profile with each
other.

Watching this takes three terminals and a browser.

First, start the browser UI with the live timeline turned on. This walkthrough uses the cleartext TCP testing adapter,
the shortest path, because it needs no transport sidecar. (The repository also has an iroh netlayer for Goblins, used by
the automated encrypted scenario. It is an adapter kept here, not a transport Goblins ships.) The TCP Rooms server
listens on port 9099:

```sh
zig build rooms-web -Dtransport=tcp -- --trace
```

Open `http://localhost:8080`, enter the room `general`, and pick a nickname. That is your glowcap member.

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

This is a chat terminal like `zig build rooms-chat`, except that the peer behind it is a Goblins vat instead of a
glowcap one. It takes the same commands (`/list`, `/open <name>`, `/enter <name>`, `/leave`, and `/help`), and Ctrl-D
quits. Anything else you type is a line in the room. The trailing `9200` is the port the vat's own netlayer binds,
which is where other members reach it privately.

What you type appears in the browser, and what the browser types appears here. On the viewer's stage, the new session
is labeled `goblins-carol` and drawn on `syrup/v1_0`, while yours stays on `capnp/next`. That is one room with two
implementations, and each connection uses the profile its own two ends agreed on.

`zig build goblins-rooms` runs the same meeting without the browser and checks it. A scripted Goblins vat and a glowcap
client exchange lines in one room, and the server's trace must show both profiles. The scripted member is
`conformance/goblins-peer/racket/rooms-member.rkt`, beside the interactive one.

## Direct-messaging the vat

Click the vat's name in the member pane and type. The room introduces the two of you and then carries none of the
conversation. Your messages go directly between your browser and the vat, and the viewer draws that as its own session,
which disappears when you close the conversation. The vat shows your messages as `(dm) <you>`, and anything it sends
back with `/dm` returns over the connection your message came in on.

Over cleartext TCP, the server needs one extra setting. The browser reaches everything through the relay, and the relay
will not open a cleartext socket to an address a page asked for. So start the server with the vat's address listed:

```sh
GLOWCAP_RELAY_TCP_PEERS=127.0.0.1:9200 zig build rooms-web -Dtransport=tcp
```

Over iroh there is nothing to list. An iroh destination must be a peer that holds the key it is named by, so the relay
can safely dial any of them. `zig build goblins-rooms-dm` and `zig build goblins-rooms-dm-iroh` run the whole
conversation over TCP and iroh respectively, and check that it appears on the timeline and then leaves it.
