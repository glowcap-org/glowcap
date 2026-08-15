import { HINT_DIRECT_ADDRESSES, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_TCP, TRANSPORT_TCP } from "@pancake/abi";
import type { Locator } from "@pancake/runtime";

/** Spell a TCP `host:port` designator, including IPv6 brackets. */
export function addressDesignator(hostname: string, port: number): string {
	if (hostname.includes(":") && !(hostname.startsWith("[") && hostname.endsWith("]"))) {
		return `[${hostname}]:${port}`;
	}
	return `${hostname}:${port}`;
}

/** Build the plain TCP profile's typed OCapN locator. */
export function locator(hostname: string, port: number): Locator {
	return {
		transport: TRANSPORT_TCP,
		designator: addressDesignator(hostname, port),
		hints: new Map(),
		hintWireForm: "boolean-false",
	};
}

function keyAddressedLocator(
	transport: string,
	designator: string,
	hostname: string,
	port: number,
): Locator {
	return {
		transport,
		designator,
		hints: new Map([[HINT_DIRECT_ADDRESSES, addressDesignator(hostname, port)]]),
		hintWireForm: "map",
	};
}

export function keyedLocator(designator: string, hostname: string, port: number): Locator {
	return keyAddressedLocator(TRANSPORT_KEYED_TCP, designator, hostname, port);
}

export function noiseLocator(designator: string, hostname: string, port: number): Locator {
	return keyAddressedLocator(TRANSPORT_NOISE_TCP, designator, hostname, port);
}
