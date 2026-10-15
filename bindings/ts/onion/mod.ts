// Public @glowcap/onion surface. Raw archive ownership lives in ffi_archive.ts;
// provider.ts composes it with the generic driver.
//
// A service id is an address, not an identity: Tor proves the far circuit holds
// the key encoded by the address, while the CapTP peer is whoever owns the local
// endpoint the service forwards to. An accepted circuit exposes no client
// identity because Tor tells a hidden service nothing about who dialed it.
//
// Raw methods are asynchronous and require an FFI runtime that dispatches
// blocking calls away from its event loop (Deno does; Bun refuses first). The
// product-level `listen` installs a provider synchronously, then awaits generic
// driver readiness. Raw listeners and connections expose borrowed readiness
// descriptors for external reactors; their methods document exact ownership.

export {
	type Auth,
	Connection,
	Listener,
	locator,
	Netlayer,
	type NetlayerOptions,
	SERVICE_ID_LENGTH,
} from "./ffi_archive.ts";
export { installProvider, listen, OnionServer, provider } from "./provider.ts";

/** This package's one profile, in its own words (`ProfileInfo`). */
export const profiles = [
	{
		transport: "onion",
		summary: "A Tor onion service, published through a running Tor.",
		reference: "https://community.torproject.org/onion-services/",
		referenceName: "onion services",
		takes: [],
	},
] as const satisfies readonly import("@glowcap/runtime/transport").ProfileInfo[];
