// The door facts of a Rooms address that every reader shares: the browser
// page, the terminal client, and the tests. This module imports only the
// generated ABI names, because the browser bundle carries it and the page has
// the Rust application in place of the runtime: a `@glowcap/runtime` import
// keeps the runtime's `node:fs` loader in the deno-compiled page. Opening an
// identity route into its doors needs the locator parser, so that lives in
// `routes.ts` beside the composition it inverts.

import { TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "@glowcap/abi";

/** Whether `locator` is an `ocapn://` URI rather than a `hostname:port`. */
export function isUriLocator(locator: string): boolean {
	return locator.includes("://");
}

/** The transports a browser opens by itself, with no Rooms server: the relay
 * doors, each naming its relay in the `rendezvous-relay` hint. Every other
 * transport reaches a directory through the Rooms server the page uses. The
 * browser's dial reads the same pair from `glowcap::browser::relay::TRANSPORTS`. */
export const BROWSER_OWN_DOORS: ReadonlySet<string> = new Set([TRANSPORT_NOISE_RELAY, TRANSPORT_KEYED_RELAY]);
export const HINT_RENDEZVOUS_RELAY = "rendezvous-relay";
