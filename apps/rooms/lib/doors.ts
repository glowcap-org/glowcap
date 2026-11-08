// The doors of a Rooms address, for every reader of one: the browser page,
// the terminal client, and the tests. This module stays free of host modules
// and of runtime calls, because the browser bundle carries it and the page
// has the Rust application in place of the runtime.

import {
	HINT_ALT_LOCATORS,
	HINT_VIA,
	type Locator,
	parseLocator,
	stringHint,
	TRANSPORT_ID,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_NOISE_RELAY,
} from "@glowcap/runtime";

/** Whether `locator` is an `ocapn://` URI rather than a `hostname:port`. */
export function isUriLocator(locator: string): boolean {
	return locator.includes("://");
}

/** The concrete locators a location opens into: the location itself, unless
 * it is an identity route, whose proving routes and fallbacks are its doors,
 * in the order the route lists them. A door that does not parse is left out
 * rather than failing the rest. */
export function roomsIdentityDoors(location: Locator): Locator[] {
	if (location.transport !== TRANSPORT_ID) return [location];
	const doors: Locator[] = [];
	for (const name of [HINT_VIA, HINT_ALT_LOCATORS]) {
		for (const uri of (stringHint(location, name) ?? "").split("|")) {
			if (uri === "") continue;
			try {
				doors.push(parseLocator(uri));
			} catch {
				// A door the route lists in a form this reader does not parse is
				// not one this reader can open, so it is not a door for it.
			}
		}
	}
	return doors;
}

/** The transports a browser opens by itself, with no Rooms server: the relay
 * doors, each naming its relay in the `rendezvous-relay` hint. Every other
 * transport reaches a directory through the Rooms server the page uses. The
 * browser's dial reads the same pair from `glowcap::browser::relay::TRANSPORTS`. */
export const BROWSER_OWN_DOORS: ReadonlySet<string> = new Set([TRANSPORT_NOISE_RELAY, TRANSPORT_KEYED_RELAY]);
export const HINT_RENDEZVOUS_RELAY = "rendezvous-relay";
