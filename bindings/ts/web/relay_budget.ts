// Time a browser relay may spend finding an FFI iroh endpoint before it can
// forward the first end-to-end handshake byte.

import { DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS } from "@glowcap/abi";

export const IROH_RELAY_DIAL_ALLOWANCE_MS = DISCOVERY_DIAL_MAX_ATTEMPTS * DISCOVERY_DIAL_RETRY_MS;
