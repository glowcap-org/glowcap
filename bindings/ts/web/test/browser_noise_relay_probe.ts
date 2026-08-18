// Runs inside Chromium for `browser_noise_relay_test.ts`. This is intentionally
// product-shaped: the page loads the shipped Wasm Host, publishes an object,
// and registers its Noise locator through the same public web/runtime surface
// an application uses.

import { init } from "@pancake/web";

declare global {
	var pancakeNoiseReady: {
		locator: string;
		finish(): Promise<string[]>;
	} | undefined;
}

const relayUrl = new URL(new URL(location.href).searchParams.get("relay") ?? "");
if (relayUrl.protocol !== "ws:" && relayUrl.protocol !== "wss:") {
	throw new Error("browser Noise probe needs a WebSocket relay URL");
}

const web = await init({ wasm: fetch("/pancake_host.wasm") });
web.host.publishGiftable("noise-greeter", (verb, args) => {
	if (verb !== "greet") throw new Error(`noise greeter has no method ${verb}`);
	return `hello ${typeof args[0] === "string" ? args[0] : "?"} from Chromium Noise`;
});
const rendezvous = web.serveRendezvous(
	web.host,
	web.TRANSPORT_NOISE_RELAY,
	{
		registerUrl: (id) => {
			const register = new URL("/register", relayUrl);
			register.searchParams.set("id", id);
			return register.href;
		},
		relayUrl: relayUrl.href,
	},
);
await rendezvous.ready();
globalThis.pancakeNoiseReady = {
	locator: web.formatLocatorUri(rendezvous.locator),
	async finish(): Promise<string[]> {
		await rendezvous.stop();
		await web.close();
		return web.host.takeFailures().map((failure) =>
			`${failure.operation}: ${failure.primaryName}: ${failure.primaryMessage}`
		);
	},
};
