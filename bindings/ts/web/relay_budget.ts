// Time a browser relay may spend finding an FFI iroh endpoint before it can
// forward the first end-to-end handshake byte.

import { DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS } from "@glowcap/abi";

/** The milliseconds a browser adds to an iroh dial's handshake budget when the dial goes through a relay, because the
 * relay may spend the core's whole discovery retry budget before it forwards the first handshake byte. */
export const IROH_RELAY_DIAL_ALLOWANCE_MS = DISCOVERY_DIAL_MAX_ATTEMPTS * DISCOVERY_DIAL_RETRY_MS;
