# Site transport examples

Author CapTP first-call snippets here once; `zig build gen-site-examples`
assembles them into SuperMD `code-tabs` blocks on the binding, Start, and
transport pages. The numbered Zig chapters and C programs live under
[`examples/`](../../examples/README.md); this directory is only the
per-transport first-call matrix. The site's Examples page is the
runnable inventory: rooms, chapters, C, and the demo apps.

A binding page already names the language, so its tabs name transports. The
tabs contain only transport-specific setup. The generator renders the common
connect/fetch/send or publish/serve continuation once and verifies that every
complete source file carries the same continuation. A transport page already
names the transport, so its tabs name languages and show only that setup.

Binding tabs follow the deployment order from Choosing a transport: production
paths first, then trusted-network paths, then testing-only paths. A page that
covers more than one transport profile gives each profile its own group when
the programs differ: the Noise page separates TCP from relay, and the relay
dial axis separates Noise from keyed cleartext. Relay listen is the sealed
path once; keyed registration is the same constructor with a different
profile, not a second full program.

## Layout

```text
site/examples/
  dial/<transport>.<lang>     # connect / fetch / send round-trip
  listen/<transport>.<lang>   # listen / publish / serve
  onion/<lang>.<lang>         # Session hosting through a configured Tor provider
  browser/<transport>.ts      # wasm dial shapes that differ by locator
```

Languages: `zig`, `ts`, `python`, `rust`, `racket`.
Fence languages match those names (`scheme` for racket).

Every complete example includes the sentence "From here, the CapTP workflow is
transport-independent." in its language's comment syntax. The generator uses
that line as the split and rejects different continuations within one language
and direction.

Start building and the binding pages share one CapTP Session dial/listen tab
set. The managed binding pages retain only the combinations they support.
The available tabs are:

| Tab | Why it earns a place |
| --- | --- |
| `iroh` | Managed native Zig, C and language-binding providers |
| `noise-tcp` | Same sockets as keyed; Noise_XK seals CapTP |
| `keyed-tcp` | Key designator, cleartext; restart-stable identity |
| `tcp` | Cleartext address dial; testing and the Goblins TCP suite |

The full inventory also includes `webrtc`, `noise-relay`, `onion`,
`keyed-relay`, and `inproc`. Onion needs Tor daemon endpoints, WebRTC needs a
signaling capability, and relay locators name the rendezvous service. In-process
dials share a Zig `Network`; managed bindings keep their in-process API at the
raw frame-transport seam.

Transport pages may also carry an explicitly marked `PLANNED` snippet for a
language whose low-level transport exists but whose managed application adapter
does not. Those planned snippets show the intended consumer shape, are excluded
from binding-page tabs, and are not compile-checked, because the API they show
is not yet public in that binding. The `PLANNED` marker is the distinction: an
unmarked example is a shipped, checked claim.

## Editing

1. Change or add a snippet file under the folders above.
2. If you add a transport or page slot, update `matrix` / `slots` in
   [`tools/gen/site_examples.zig`](../../tools/gen/site_examples.zig).
3. Run `zig build gen-site-examples`, or keep `zig build docs-serve` running —
   the preview regenerates tabs on start and whenever `site/examples/` (or the
   assembler) changes.
4. `zig build gen-site-examples-check` (on `check`) fails when a page marker is
   stale.
5. The `site-*-examples-check` steps compile or type-check every shipped source
   file through the same public packages readers use. Explicit `PLANNED`
   snippets are skipped, because the API they show is not yet public.

Do not hand-edit between the begin/end markers in `site/content/**/*.smd`;
the gen step overwrites that span. Each marker is an HTML comment inside a
` ```=html ` fence so SuperMD accepts it (same escape as the performance page).
