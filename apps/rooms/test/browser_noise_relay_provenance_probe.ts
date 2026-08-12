// The page half of the direct browser Noise-relay provenance proof. The
// acceptor parks a public @pancake/web Host at serve.ts's rendezvous relay;
// the dialer opens a live noise-relay Session and reads its public
// partnerIdentity() before making the capability call.

import { init } from "@pancake/web";

const params = new URLSearchParams(location.search);
const role = params.get("role");
const target = params.get("target");
const status = document.getElementById("status")!;
const wasm = fetch("/pancake_host.wasm");

function relayBase(path: string): string {
	const protocol = location.protocol === "https:" ? "wss://" : "ws://";
	return `${protocol}${location.host}${path}`;
}

function relayUrl(path: string, parameter: string, value: string): string {
	return `${relayBase(path)}?${parameter}=${encodeURIComponent(value)}`;
}

function delay(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function accept(stack: typeof import("@pancake/stack")): Promise<void> {
	const host = new stack.Host(new Uint8Array(32).fill(0xa1));
	host.publishGiftable("greeter", (verb, args) => {
		if (verb !== "greet") throw new Error(`unexpected verb ${verb}`);
		return `hello ${String(args[0] ?? "browser")}`;
	});
	stack.serveRendezvous(
		host,
		stack.TRANSPORT_NOISE_RELAY,
		{
			registerUrl: (designator) => relayUrl("/register", "id", designator),
			relayUrl: relayBase("/relay"),
		},
	);
	status.textContent = `READY:${host.designator()}`;
}

async function dial(stack: typeof import("@pancake/stack")): Promise<void> {
	if (target === null || target === "") throw new Error("missing acceptor designator");
	const host = new stack.Host(new Uint8Array(32).fill(0xb2));
	host.setRendezvousUrl((designator) => relayUrl("/relay", "rendezvous", designator));
	const locator = stack.formatPeerUri(stack.TRANSPORT_NOISE_RELAY, target);

	let session: import("@pancake/stack").Session | null = null;
	let lastError: unknown = null;
	// Registration is asynchronous. Retry the public dial until the acceptor's
	// rendezvous socket is parked, while keeping the whole browser probe bounded
	// by its harness timeout.
	for (let attempt = 0; attempt < 40; attempt++) {
		try {
			session = await stack.connect(locator, undefined, host);
			break;
		} catch (error) {
			lastError = error;
			await delay(100);
		}
	}
	if (session === null) {
		throw new Error(`noise-relay dial did not open: ${String(lastError)}`);
	}

	try {
		const identity = session.partnerIdentity();
		if (identity.provenance !== "authenticated-transport") {
			throw new Error(
				`expected authenticated-transport provenance, got ${identity.provenance}`,
			);
		}
		session.serve().catch(() => {});
		const greeter = await session.fetch("greeter");
		const reply = await session.send(greeter, "greet", ["browser"]);
		if (reply !== "hello browser") throw new Error(`unexpected reply ${String(reply)}`);
		status.textContent = `OK:${JSON.stringify({ provenance: identity.provenance })}`;
	} finally {
		await session.close();
	}
}

async function main(): Promise<void> {
	const stack = await init({ wasm });
	if (role === "accept") return accept(stack);
	if (role === "dial") return dial(stack);
	throw new Error(`unknown probe role ${String(role)}`);
}

main()
	.catch((error) => {
		status.textContent = `ERR:${error instanceof Error ? error.message : String(error)}`;
	})
	.finally(() => {
		status.dataset.done = "1";
	});
