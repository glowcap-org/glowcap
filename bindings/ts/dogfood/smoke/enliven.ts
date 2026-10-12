// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// Sturdy references become live capabilities through an existing session or a
// host-selected dial, with peer and protocol-version identity enforced.

import * as tcp from "@glowcap/tcp";
import { INVALID_ARGUMENT } from "@glowcap/abi";

import { formatLocatorUri, GlowcapError, Host, Runtime, Sym, VowBroken } from "../../runtime/mod.ts";

import { assert, ok } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	// Sturdyref enliven (ADR-0012): the requester brings a durable (peer, swissnum)
	// to life as a live Ref through the host's dedup cache. A repeat enliven of the
	// same swissnum short-circuits with no wire traffic (its completion is queued
	// before the minting call returns), and the enlivened cap is sendable both
	// times.
	{
		await using serverHost = new Host();
		serverHost.publish("greeter", (verb) => {
			assert(verb === "hello", `enliven server expected hello, got ${verb}`);
			return new Sym("alive");
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const locator = tcp.locator("127.0.0.1", port);
			const session = await managed.connect(locator);
			session.serve().catch(() => {});
			let mismatchRefused = false;
			try {
				await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg");
			} catch (err) {
				mismatchRefused = err instanceof GlowcapError && err.code === INVALID_ARGUMENT;
			}
			assert(mismatchRefused, "enliven accepted a sturdyref for another peer");
			// The complete sturdyref must name this selected session's peer.
			const sturdyref = `${formatLocatorUri(locator)}/s/Z3JlZXRlcg`;
			const cap = await session.enliven(sturdyref);
			const greeting = await session.send(cap, "hello", []);
			assert(
				greeting instanceof Sym && (greeting as Sym).value === "alive",
				"enlivened cap answers hello",
			);
			// A repeat enliven hits the dedup cache: the same live capability, sendable.
			const again = await session.enliven(sturdyref);
			assert(cap.equals(again), "cached enliven preserves Target equality");
			const greeting2 = await session.send(again, "hello", []);
			assert(
				greeting2 instanceof Sym && (greeting2 as Sym).value === "alive",
				"cached enliven answers hello",
			);
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok(
			"a sturdyref enlivens to a live capability, and a repeat enliven hits the cache",
		);
	}

	// Select-or-dial enliven (ADR-0098 step 4): the *host* enlivens a complete
	// sturdyref with no session named. A peer it already dialed is selected, so
	// this arm settles over that live session. The dial arm is the same verb
	// with an unreached peer, driven by the host's own DIAL action.
	{
		await using serverHost = new Host();
		serverHost.publish("beacon", () => new Sym("lit"));
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const locator = tcp.locator("127.0.0.1", port);
			const shared = new Host();
			await using sharedRuntime = await Runtime.open({
				providers: [tcp.provider()],
				adoptHost: shared,
			});
			const session = await sharedRuntime.connect(locator);
			session.serve().catch(() => {});
			const sturdyref = `${formatLocatorUri(locator)}/s/YmVhY29u`;
			const cap = await shared.enliven(sturdyref, "v1_0");
			const greeting = await session.send(cap, "hello", []);
			assert(
				greeting instanceof Sym && (greeting as Sym).value === "lit",
				"the select-or-dial enlivened cap answers",
			);
			let wrongVersion = false;
			try {
				await shared.enliven(sturdyref, "next");
			} catch (error) {
				wrongVersion = error instanceof VowBroken;
			}
			assert(wrongVersion, "next must not reinterpret a v1.0 swiss as the same authority");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a host selects a live session to enliven a sturdyref over");
	}
}
