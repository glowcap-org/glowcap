// Relay-owned locator and WebSocket-route policy for managed runtimes.
//
// The FFI provider enforces the same contract in Zig. This projection
// validates before a runtime WebSocket can perform I/O and preserves admitted
// route bytes when appending Glowcap's owned rendezvous query.

import {
	INVALID_ARGUMENT,
	RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_NOISE_RELAY,
} from "@glowcap/abi";
import { GlowcapError, isKeyDesignator, type Locator } from "@glowcap/runtime/transport";

const RENDEZVOUS_RELAY_HINT = "rendezvous-relay";
const RENDEZVOUS_QUERY = "rendezvous";
const REGISTER_QUERY = "id";
const encoder = new TextEncoder();

function invalid(message: string): never {
	throw new GlowcapError(INVALID_ARGUMENT, message);
}

function validateDesignator(designator: string): void {
	if (!isKeyDesignator(designator)) {
		invalid("relay designator must be 64 lowercase hexadecimal characters");
	}
}

function hasMalformedPercentEncoding(value: string): boolean {
	for (let at = 0; at < value.length; at++) {
		if (value.charCodeAt(at) !== 0x25) continue;
		if (at + 2 >= value.length || !/^[0-9a-fA-F]{2}$/.test(value.slice(at + 1, at + 3))) {
			return true;
		}
		at += 2;
	}
	return false;
}

function validateHostname(url: URL): void {
	const host = url.hostname;
	if (host.startsWith("[") && host.endsWith("]")) return;
	for (const label of host.split(".")) {
		if (
			label.length === 0 || label.length > 63 ||
			!/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label)
		) {
			invalid("rendezvous-relay carries an invalid host name");
		}
	}
}

function encodedQueryName(field: string): string {
	const equals = field.indexOf("=");
	const name = equals < 0 ? field : field.slice(0, equals);
	return name.replaceAll(
		/%([0-9a-fA-F]{2})/g,
		(_whole, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)),
	);
}

export function relayRoute(value: unknown): string {
	if (typeof value !== "string" || value.length === 0) {
		invalid("rendezvous-relay must be a non-empty string hint");
	}
	if (encoder.encode(value).byteLength > RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES) {
		invalid(`rendezvous-relay exceeds ${RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES} UTF-8 bytes`);
	}
	for (let at = 0; at < value.length; at++) {
		const code = value.charCodeAt(at);
		if (code < 0x21 || code > 0x7e) invalid("rendezvous-relay must contain visible ASCII URI bytes");
	}
	if (hasMalformedPercentEncoding(value)) invalid("rendezvous-relay carries malformed percent encoding");

	let url: URL;
	try {
		url = new URL(value);
	} catch {
		invalid("rendezvous-relay must be an absolute WebSocket URL");
	}
	if (url.protocol !== "ws:" && url.protocol !== "wss:") {
		invalid("rendezvous-relay must use ws or wss");
	}
	if (url.username !== "" || url.password !== "" || url.hash !== "") {
		invalid("rendezvous-relay cannot carry credentials or a fragment");
	}
	if (url.port === "0") invalid("rendezvous-relay carries an invalid port");
	validateHostname(url);
	const queryAt = value.indexOf("?");
	if (queryAt >= 0) {
		for (const field of value.slice(queryAt + 1).split("&")) {
			const name = encodedQueryName(field);
			if (name === RENDEZVOUS_QUERY || name === REGISTER_QUERY) {
				invalid(`rendezvous-relay reserves the ${name} query parameter`);
			}
		}
	}
	return value;
}

function profileLocator(transport: string, designator: string, relayUrl: string): Locator {
	validateDesignator(designator);
	const route = relayRoute(relayUrl);
	return {
		transport,
		designator,
		hints: new Map([[RENDEZVOUS_RELAY_HINT, route]]),
		hintWireForm: "map",
	};
}

/** The identity-addressed cleartext relay profile. */
export const keyed = {
	locator(designator: string, relayUrl: string): Locator {
		return profileLocator(TRANSPORT_KEYED_RELAY, designator, relayUrl);
	},
};

/** The Noise_XK-sealed relay profile. */
export const noise = {
	locator(designator: string, relayUrl: string): Locator {
		return profileLocator(TRANSPORT_NOISE_RELAY, designator, relayUrl);
	},
};

export function routeFromLocator(locator: Locator): string | null {
	const value = locator.hints.get(RENDEZVOUS_RELAY_HINT);
	if (value == null) return null;
	return relayRoute(value);
}

export function dialUrl(route: string, designator: string): string {
	validateDesignator(designator);
	const admitted = relayRoute(route);
	return `${admitted}${admitted.includes("?") ? "&" : "?"}${RENDEZVOUS_QUERY}=${designator}`;
}
