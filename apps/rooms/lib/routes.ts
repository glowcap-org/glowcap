import {
	formatLocatorUri,
	formatPeerUri,
	HINT_ALT_LOCATORS,
	HINT_VIA,
	type Locator,
	TRANSPORT_ID,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_ONION,
	TRANSPORT_TCP,
} from "@pancake/runtime";
import { roomsLocator } from "./locator.ts";

const ROUTE_ORDER = [TRANSPORT_IROH, TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP] as const;
const FALLBACK_ORDER = [TRANSPORT_ONION, TRANSPORT_TCP, TRANSPORT_KEYED_TCP, TRANSPORT_KEYED_RELAY] as const;

/** The stable authority Rooms uses to file one directory.
 *
 * An identity route and each transport that proves its Host key name the same
 * peer when their designators match. Weak fallback transports remain separate:
 * reaching the same process over cleartext TCP does not prove it is the holder
 * of an `id` route's key. This shares `ROUTE_ORDER`, the route composer's one
 * authority for that distinction. */
export function roomsPeerAuthority(locator: Locator): string {
	const provesHost = locator.transport === TRANSPORT_ID ||
		ROUTE_ORDER.includes(locator.transport as (typeof ROUTE_ORDER)[number]);
	return formatPeerUri(provesHost ? TRANSPORT_ID : locator.transport, locator.designator);
}

/** Compose the identity-first location a Rooms host may advertise.
 *
 * Key-proving listeners establish the identity; baseline listeners remain weak
 * handoff fallbacks for peers that do not speak the route vocabulary. One
 * proving route without added reachability stays a concrete locator. */
export function roomsIdentityRoute(hostKey: string, locatorUris: readonly string[]): Locator | null {
	const byTransport = new Map<string, Locator>();
	for (const uri of locatorUris) {
		let route: Locator;
		try {
			route = roomsLocator(uri);
		} catch {
			continue;
		}
		const strong = ROUTE_ORDER.includes(route.transport as (typeof ROUTE_ORDER)[number]);
		const weak = FALLBACK_ORDER.includes(route.transport as (typeof FALLBACK_ORDER)[number]);
		if (!strong && !weak) continue;
		if (strong && route.designator !== hostKey) continue;
		byTransport.set(route.transport, route);
	}
	const routes = ROUTE_ORDER.flatMap((transport) => {
		const route = byTransport.get(transport);
		return route === undefined ? [] : [route];
	});
	const fallbacks = FALLBACK_ORDER.flatMap((transport) => {
		const route = byTransport.get(transport);
		return route === undefined ? [] : [route];
	});
	if (routes.length === 0 || routes.length + fallbacks.length < 2) return null;
	const hints = new Map([[HINT_VIA, routes.map(formatLocatorUri).join("|")]]);
	if (fallbacks.length > 0) hints.set(HINT_ALT_LOCATORS, fallbacks.map(formatLocatorUri).join("|"));
	return {
		transport: TRANSPORT_ID,
		designator: hostKey,
		hints,
		hintWireForm: "map",
	};
}
