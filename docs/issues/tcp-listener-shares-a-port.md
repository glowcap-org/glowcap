# Two TCP listeners can hold one address, and both report success

`src/net/transport/tcp_runtime.zig` listens with `.reuse_address = true`, which
on Linux sets `SO_REUSEPORT` as well as `SO_REUSEADDR`. Two processes can then
bind the same address at the same time, and the kernel shares arriving
connections between them.

Reproduced with the rooms server, which is only the easiest way to see it:

```
$ deno run … apps/rooms/server/main.ts 45351 &   # ROOMS-SERVER-LISTENING 45351
$ deno run … apps/rooms/server/main.ts 45351 &   # ROOMS-SERVER-LISTENING 45351
$ ss -ltn | grep 45351
LISTEN 0 128 127.0.0.1:45351 0.0.0.0:*
LISTEN 0 128 127.0.0.1:45351 0.0.0.0:*
```

Both announce that they are listening, and neither can tell it is sharing.

Why it matters here rather than in an ordinary server: a pancake listener is a
Host with a retained identity, so two of them on one address means a dialer
reaching that address gets one of two different peers, chosen per connection by
the kernel. In the rooms application that surfaces as two members joining the
same room name at the same address and never seeing each other, with no error
on either side.

`SO_REUSEPORT` is a deliberate choice for a pool of workers behind one address.
It is not obviously the right default for a listener whose whole purpose is to
be one identifiable peer, and the two cases want opposite behaviour, so this is
a decision for whoever owns the transport rather than a bug to patch.

Not fixed here: this is core, and the rooms application is the reporter rather
than the owner. The application-level guard, if the default stays, is for a
server to refuse a fixed port that already answers — `apps/rooms/web/serve.ts`
already does exactly that for its supervised child (`isRoomsServer`,
attach-or-take-over), and the standalone server has no equivalent.
