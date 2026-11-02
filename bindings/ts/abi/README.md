# @glowcap/abi

`@glowcap/abi` holds the constants that glowcap's TypeScript packages share: transport ids,
return codes, size limits, and the policy values the relay and the browser adapter enforce. The
file is generated from the C library's declarations, so the packages agree with the libraries
they load.

Applications install it through the package that needs it. [`@glowcap/runtime`](https://jsr.io/@glowcap/runtime)
is the core package, and its page lists the transport packages. Import a constant directly when
a configuration value should match the library's default:

```ts
import { BINDING_RELAY_IDLE_TIMEOUT_MS, BINDING_RELAY_MAX_BYTES_PER_SESSION } from "@glowcap/abi";
```

The 64-bit struct layouts live in `@glowcap/runtime`, and the browser reads its own layout from
the Wasm module.

glowcap is built with AI coding assistants. The maintainer directs the work and is answerable for
what lands, as [How glowcap is built](https://github.com/glowcap-org/glowcap/blob/main/PROVENANCE.md)
explains.
