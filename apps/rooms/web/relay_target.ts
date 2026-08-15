import {
	designatorHostPort,
	formatLocatorUri,
	HINT_DIRECT_ADDRESSES,
	PancakeError,
	parseLocator,
	stringHint,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "@pancake/runtime";
import { INVALID_ARGUMENT } from "@pancake/abi";
import { isRendezvousDesignator } from "@pancake/relay";

/** A byte-channel target accepted by the rooms relay. */
export type RelayTarget =
	| { readonly kind: "tcp"; readonly hostname: string; readonly port: number }
	| { readonly kind: "iroh"; readonly locator: string };

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
			throw new PancakeError(INVALID_ARGUMENT, "iroh relay target requires a canonical node id");
		}
		return { kind: "iroh", locator: formatLocatorUri(locator) };
	}
	if (
		locator.transport === TRANSPORT_KEYED_TCP ||
		locator.transport === TRANSPORT_NOISE_TCP
	) {
		const address = stringHint(locator, HINT_DIRECT_ADDRESSES);
		if (address == null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`${locator.transport} relay target requires a direct-addresses hint`,
			);
		}
		return { kind: "tcp", ...designatorHostPort(address) };
	}
	if (locator.transport === TRANSPORT_TCP) {
		return { kind: "tcp", ...designatorHostPort(locator.designator) };
	}
	throw new PancakeError(
		INVALID_ARGUMENT,
		`rooms relay cannot dial transport ${JSON.stringify(locator.transport)}`,
	);
}
