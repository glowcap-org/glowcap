// Rooms sturdyrefs and addresses a test builds from parts.

import { formatLocatorUri, formatSturdyRef, type Locator, TRANSPORT_TCP } from "@glowcap/runtime";
import { parseRoomsSturdyref, ROOMS_STURDYREF_VERSION } from "../../lib/locator.ts";

export function formatRoomsSturdyref(locator: Locator, swissnum: string | Uint8Array): string {
	return formatSturdyRef(locator, swissnum, ROOMS_STURDYREF_VERSION);
}

export function roomsSturdyrefLocator(sturdyref: string): Locator {
	return parseRoomsSturdyref(sturdyref).locator;
}

/** A parsed locator in the form `dial` accepts: a TCP peer as its `host:port`
 * designator, every other transport as its complete URI. */
export function roomsAddress(locator: Locator): string {
	return locator.transport === TRANSPORT_TCP ? locator.designator : formatLocatorUri(locator);
}
