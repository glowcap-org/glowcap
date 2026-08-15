// The TCP provider package owns locator construction and native listening for
// all three profiles it advertises. Importing the package remains safe before a
// browser installs its wasm runtime adapter: native code loads only when a
// listener or `@pancake/tcp/transport` operation is used.

import { keyedLocator, noiseLocator } from "./address.ts";
import type { KeyedListenOptions, ListenOptions, Server } from "./listen.ts";

export { addressDesignator, locator } from "./address.ts";
export type { KeyedListenOptions, ListenOptions, Server } from "./listen.ts";
export type { Config, Keepalive, OperationOptions, StreamOptions } from "./transport.ts";
export { options, provider } from "./transport.ts";

/** Bind the plain profile through this package's native provider. */
export async function listen(
	hostname: string,
	port: number,
	options: ListenOptions = {},
): Promise<Server> {
	return await (await import("./listen.ts")).listen(hostname, port, options);
}

async function listenKeyed(
	hostname: string,
	port: number,
	options: KeyedListenOptions = {},
): Promise<Server> {
	return await (await import("./listen.ts")).listenKeyed(hostname, port, options);
}

async function listenNoise(
	hostname: string,
	port: number,
	options: KeyedListenOptions = {},
): Promise<Server> {
	return await (await import("./listen.ts")).listenNoise(hostname, port, options);
}

/** The identity-addressed cleartext profile over this TCP package. */
export const keyed = {
	locator: keyedLocator,
	listen: listenKeyed,
};

/** The Noise_XK-sealed profile over this TCP package. */
export const noise = {
	locator: noiseLocator,
	listen: listenNoise,
};
