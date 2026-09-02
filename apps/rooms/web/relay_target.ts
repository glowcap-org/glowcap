import {
	designatorHostPort,
	formatLocatorUri,
	GlowcapError,
	HINT_DIRECT_ADDRESSES,
	parseLocator,
	stringHint,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "@glowcap/runtime";
import { INVALID_ARGUMENT, TRANSPORT_ONION } from "@glowcap/abi";
import { isRendezvousDesignator } from "@glowcap/relay";

/** A byte-channel target accepted by the rooms relay. */
export type RelayTarget =
	| { readonly kind: "tcp"; readonly hostname: string; readonly port: number }
	| { readonly kind: "iroh"; readonly locator: string }
	| { readonly kind: "onion"; readonly designator: string };

/** The service id an `ocapn://…onion` locator names, or null for anything
 * else. The relay uses it to recognize the supervised room's own service. */
export function onionDesignator(locator: string): string | null {
	try {
		const parsed = parseLocator(locator);
		return parsed.transport === TRANSPORT_ONION ? parsed.designator : null;
	} catch {
		return null;
	}
}

/** Classify one rooms-relay target at the product edge that realizes it. */
export function classifyRelayTarget(input: string): RelayTarget {
	if (!input.includes("://")) {
		return { kind: "tcp", ...designatorHostPort(input) };
	}
	const locator = parseLocator(input);
	if (locator.transport === TRANSPORT_IROH) {
		// The node id keys the dial; a malformed one is refused here rather
		// than handed to the iroh dialer as an attacker-shaped map key. Same
		// canonical 64-hex shape the rendezvous designator check owns.
		if (!isRendezvousDesignator(locator.designator)) {
			throw new GlowcapError(INVALID_ARGUMENT, "iroh relay target requires a canonical node id");
		}
		return { kind: "iroh", locator: formatLocatorUri(locator) };
	}
	if (
		locator.transport === TRANSPORT_KEYED_TCP ||
		locator.transport === TRANSPORT_NOISE_TCP
	) {
		const address = stringHint(locator, HINT_DIRECT_ADDRESSES);
		if (address == null) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`${locator.transport} relay target requires a direct-addresses hint`,
			);
		}
		return { kind: "tcp", ...designatorHostPort(address) };
	}
	if (locator.transport === TRANSPORT_TCP) {
		return { kind: "tcp", ...designatorHostPort(locator.designator) };
	}
	// A wire-carried onion locator stays bare (ADR-0118), so the service id is
	// the whole target; whether it names the supervised room is admission's
	// question, not classification's.
	if (locator.transport === TRANSPORT_ONION) {
		return { kind: "onion", designator: locator.designator };
	}
	throw new GlowcapError(
		INVALID_ARGUMENT,
		`rooms relay cannot dial transport ${JSON.stringify(locator.transport)}`,
	);
}
