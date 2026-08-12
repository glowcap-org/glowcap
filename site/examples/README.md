# Site transport examples

Author CapTP first-call snippets here once; `zig build gen-site-examples`
assembles them into SuperMD `code-tabs` blocks on the binding and Start pages.

## Layout

```text
site/examples/
  dial/<transport>.<lang>     # connect / fetch / send round-trip
  listen/<transport>.<lang>   # listen / publish / serve
  onion/<lang>                # Tor Netlayer surface (not CapTP Session)
  browser/<transport>.ts      # wasm dial shapes that differ by locator
```

Languages: `zig`, `ts`, `python`, `rust`, `racket`.
Fence languages match those names (`scheme` for racket).

Transports on the CapTP Session dial/listen tabs (same CapTP verbs; locator /
listen / provider differs):

| Tab | Why it earns a place |
| --- | --- |
| `tcp` | Cleartext address dial; testing and Goblins TCP suite |
| `keyed-tcp` | Key designator, cleartext; restart-stable identity |
| `noise-tcp` | Same sockets as keyed; Noise_XK seals CapTP |
| `iroh` | Node-id URI + discovery reachability; optional archive |

`onion` and browser relay tabs live in their own folders because the API shape
differs (Tor Netlayer vs Session; wasm + relay URL options). Do not force them
into the Session dial group.

## Editing

1. Change or add a snippet file under the folders above.
2. If you add a transport or page slot, update `TabSet` / `slots` in
   [`tools/gen/site_examples.zig`](../../tools/gen/site_examples.zig).
3. Run `zig build gen-site-examples`.
4. `zig build gen-site-examples-check` (on `check`) fails when a page marker is
   stale.

Do not hand-edit between the begin/end markers in `site/content/**/*.smd`;
the gen step overwrites that span. Each marker is an HTML comment inside a
` ```=html ` fence so SuperMD accepts it (same escape as the performance page).
