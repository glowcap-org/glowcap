// The listener-admin capability (`--admin-listeners`), end to end.
//
// The capability is a second Host publication under an unguessable swiss, so
// these prove the whole contract: nothing is minted without the flag, `list`
// answers one seat per transport the server can realize (described in the
// owning package's own words), `up` and `down` round-trip runtime listeners
// on the tcp family and the relay rendezvous, the listener carrying the
// announced locator refuses to go down, and every refusal carries its typed
// code.

import {
	LISTENER_SERVING,
	LISTENER_TRANSPORT_HELD,
	LISTENER_UNSUPPORTED,
	NO_SUCH_LISTENER,
	roomErrorOf,
} from "../../lib/errors.ts";
import { dialDirectory, loopbackTcpDesignator, parseRoomsSturdyref, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { ADVERTISED_LOCATION, DIRECTORY, LIST } from "../../lib/protocol.ts";
import { UP } from "../../lib/protocol_operator.ts";
import { ListenerRegistry } from "../../server/listeners.ts";
import { listenersBehavior } from "../../server/listeners/behavior.ts";
import {
	Directory,
	listenerDown,
	type ListenerRow,
	listenerUp,
	listListeners,
	Room,
	takeListeners,
} from "../../lib/room/client.ts";
import {
	assert,
	assertMatch,
	DENO_FLAGS,
	dial,
	enterOrOpen,
	freePort,
	IROH_FLAGS,
	irohUsable,
	readAnnounce,
	readPort,
	roomsTest,
	ROOT,
	SERVER,
	stopServer,
	within,
} from "../support/rooms_server.ts";
import {
	FEATURE_MULTI_LOCATION,
	HINT_ALT_LOCATORS,
	HINT_VIA,
	parseLocator,
	stringHint,
	TRANSPORT_ID,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_TCP,
} from "@pancake/runtime";
import type { Ref, Session } from "@pancake/runtime";
import { spawnOwned, stopOwned } from "../support/children.ts";

Deno.test("the listeners capability admits exact data before consulting the registry", () => {
	let read = false;
	let raised = false;
	const registry = {
		rows: () => {
			read = true;
			return [];
		},
		up: () => {
			raised = true;
			return Promise.resolve({});
		},
	} as unknown as ListenerRegistry;
	const listeners = listenersBehavior(registry);
	let refused = false;
	try {
		listeners(LIST, ["surplus"]);
	} catch {
		refused = true;
	}
	assert(refused, "listeners list accepted surplus data");
	assert(!read, "listeners list read the registry before refusing surplus data");
	refused = false;
	try {
		listeners(UP, ["tcp", [["port", 9000], ["port", 9001]]]);
	} catch {
		refused = true;
	}
	assert(refused, "listeners up silently chose between duplicate options");
	assert(!raised, "listeners up reached the registry with duplicate options");
});

function spawnAdminServer(stateDir: string, extraEnv: Record<string, string> = {}): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0", "--admin-listeners"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: stateDir, ...extraEnv },
		stdout: "piped",
		stderr: "piped",
	});
}

async function takeAdmin(session: Session, stateDir: string): Promise<{ cap: Ref; rows: ListenerRow[] }> {
	const swiss = (await Deno.readTextFile(`${stateDir}/admin-listeners`)).trim();
	assert(swiss.length > 0, "the server did not write a listeners swiss");
	return await takeListeners(session, swiss);
}

function seat(rows: readonly ListenerRow[], transport: string): ListenerRow {
	const found = rows.find((row) => row.transport === transport);
	assert(found !== undefined, `no ${transport} seat in ${JSON.stringify(rows)}`);
	return found;
}

function liveCount(rows: readonly ListenerRow[]): number {
	return rows.filter((row) => row.id !== null).length;
}

/** The reference relay from `@pancake/relay`, spawned for the rendezvous
 * round trip; it prints `DENO-RELAY-READY <port>` once listening. */
async function spawnRelay(): Promise<{ proc: Deno.ChildProcess; url: string }> {
	const proc = spawnOwned("deno", {
		args: [
			"run",
			"--allow-net",
			"--allow-ffi",
			"--allow-env",
			"--allow-read",
			"bindings/ts/relay/serve.ts",
			"0",
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "inherit",
	});
	const reader = proc.stdout.getReader();
	let text = "";
	const decoder = new TextDecoder();
	while (!text.includes("DENO-RELAY-READY")) {
		const { value, done } = await within(reader.read(), "the relay announce line", 20_000);
		if (done) break;
		text += decoder.decode(value);
	}
	reader.releaseLock();
	proc.stdout.cancel().catch(() => {});
	const port = text.match(/DENO-RELAY-READY (\d+)/)?.[1];
	assert(port !== undefined, `the reference relay did not announce: "${text}"`);
	return { proc, url: `ws://127.0.0.1:${port}/` };
}

roomsTest("the seat list, the serving listener, held transports, and unsupported ones", async () => {
	const stateDir = await Deno.makeTempDir();
	// No Tor endpoints reach this child, so its onion refusal is the built-in
	// boundary this test pins rather than an accident of the host environment.
	const proc = spawnAdminServer(stateDir, { PANCAKE_ONION_SOCKS: "", PANCAKE_ONION_CONTROL: "" });
	try {
		const port = await readPort(proc);
		const bootLocator = loopbackTcpDesignator(port);
		const session = await dial(bootLocator);
		session.serve().catch(() => {});
		const taken = await takeAdmin(session, stateDir);

		// One seat per transport, every one described in its owning package's
		// words, and only the boot listener live — wearing the serving marker,
		// verified against the announced locator rather than assumed by
		// position.
		assert(taken.rows.length >= 5, `expected the full seat list: ${JSON.stringify(taken.rows)}`);
		for (const row of taken.rows) {
			assert(row.description.length > 0, `the ${row.transport} seat carries no description`);
		}
		assert(liveCount(taken.rows) === 1, "expected only the boot listener live");

		// Each seat lists the knobs its up accepts: the tcp family binds a
		// host and port and may advertise another, the relay family names its
		// relay. What a blank field means is the server's own default.
		const tcpKnobs = seat(taken.rows, TRANSPORT_KEYED_TCP).takes.map((knob) => knob.name);
		assert(
			["bind", "port", "advertise"].every((name) => tcpKnobs.includes(name)),
			`the keyed-tcp seat does not list its knobs: ${JSON.stringify(tcpKnobs)}`,
		);
		const relayKnobs = seat(taken.rows, "keyed-relay").takes;
		assert(
			relayKnobs.length === 1 && relayKnobs[0].name === "relay" && relayKnobs[0].kind === "url",
			`the keyed-relay seat does not list its relay knob: ${JSON.stringify(relayKnobs)}`,
		);

		const boot = seat(taken.rows, "tcp");
		assert(boot.id !== null && boot.serving, "the boot tcp seat is not live and serving");
		assert(boot.locator === bootLocator, "the boot seat does not wear the announced locator");

		// The onion seat already knows an up would refuse: no Tor reached this
		// server, and the standing sentence says so before anyone asks.
		const onionSeat = seat(taken.rows, "onion");
		assert(
			/running Tor/.test(onionSeat.unavailable),
			`onion carries no standing answer: ${JSON.stringify(onionSeat)}`,
		);

		// The announced listener carries the web relay and this very session, so
		// down refuses and the seat stays live.
		let kept = "";
		try {
			await listenerDown(session, taken.cap, boot.id!);
		} catch (err) {
			kept = roomErrorOf(err)?.code ?? "";
		}
		assert(kept === LISTENER_SERVING, `expected ${LISTENER_SERVING}, got "${kept}"`);
		const still = await listListeners(session, taken.cap);
		assert(liveCount(still) === 1, "the refused down still removed a listener");

		// A second tcp listener while the boot one lives: the server holds one
		// live listener per transport, and the refusal says so.
		let held = "";
		try {
			await listenerUp(session, taken.cap, "tcp");
		} catch (err) {
			held = roomErrorOf(err)?.code ?? "";
		}
		assert(held === LISTENER_TRANSPORT_HELD, `expected ${LISTENER_TRANSPORT_HELD}, got "${held}"`);

		// Onion without a running Tor, a relay profile with no relay named
		// anywhere, and a name that is no transport at all.
		let onion = "";
		try {
			await listenerUp(session, taken.cap, "onion");
		} catch (err) {
			onion = roomErrorOf(err)?.code ?? "";
		}
		assert(onion === LISTENER_UNSUPPORTED, `expected ${LISTENER_UNSUPPORTED} for onion, got "${onion}"`);
		let bare = "";
		try {
			await listenerUp(session, taken.cap, "keyed-relay");
		} catch (err) {
			bare = roomErrorOf(err)?.code ?? "";
		}
		assert(bare === LISTENER_UNSUPPORTED, `expected ${LISTENER_UNSUPPORTED} for a relayless up, got "${bare}"`);
		let unreachable = "";
		try {
			await listenerUp(session, taken.cap, "keyed-relay", { relay: "ws://127.0.0.1:1/" });
		} catch (err) {
			unreachable = roomErrorOf(err)?.code ?? "";
		}
		assert(
			unreachable === LISTENER_UNSUPPORTED,
			`expected ${LISTENER_UNSUPPORTED} for an unreachable relay, got "${unreachable}"`,
		);
		let unknown = "";
		try {
			await listenerUp(session, taken.cap, "carrier-pigeon");
		} catch (err) {
			unknown = roomErrorOf(err)?.code ?? "";
		}
		assert(
			unknown === LISTENER_UNSUPPORTED,
			`expected ${LISTENER_UNSUPPORTED} for an unknown name, got "${unknown}"`,
		);

		// Down on a number nothing wears.
		let missing = "";
		try {
			await listenerDown(session, taken.cap, 999);
		} catch (err) {
			missing = roomErrorOf(err)?.code ?? "";
		}
		assert(missing === NO_SUCH_LISTENER, `expected ${NO_SUCH_LISTENER}, got "${missing}"`);
	} finally {
		await stopServer(proc);
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("a keyed-tcp listener rides up and down beside the serving one", async () => {
	// keyed-tcp holds its own seat, so unlike the plain-tcp round trip below it
	// needs no iroh boot: the boot listener keeps tcp and the keyed profile
	// comes up beside it.
	const stateDir = await Deno.makeTempDir();
	const proc = spawnAdminServer(stateDir);
	try {
		const port = await readPort(proc);
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const taken = await takeAdmin(session, stateDir);

		// A named bind and port land in the listener, and the locator shows the
		// port; a knob the seat never listed refuses in words.
		const askedPort = freePort();
		const brought = await listenerUp(session, taken.cap, TRANSPORT_KEYED_TCP, {
			bind: "127.0.0.1",
			port: askedPort,
		});
		assert(brought.transport === TRANSPORT_KEYED_TCP && brought.id !== null, "the keyed-tcp seat did not come up");
		assert(!brought.serving, "the new keyed-tcp listener claims to be serving");
		assertMatch(brought.locator ?? "", /^ocapn:\/\/.+\.keyed-tcp/);
		assert(
			(brought.locator ?? "").includes(String(askedPort)),
			`the keyed-tcp locator does not carry the asked port ${askedPort}: ${brought.locator}`,
		);
		let bogus = "";
		try {
			await listenerUp(session, taken.cap, "iroh", { port: 1 });
		} catch (err) {
			bogus = err instanceof Error ? err.message : String(err);
		}
		assert(/no "port" option/.test(bogus), `an unlisted knob was not refused in words: "${bogus}"`);

		const two = await listListeners(session, taken.cap);
		assert(liveCount(two) === 2, `expected two live listeners after up: ${JSON.stringify(two)}`);

		await listenerDown(session, taken.cap, brought.id!);
		const one = await listListeners(session, taken.cap);
		assert(liveCount(one) === 1 && seat(one, "tcp").serving, "expected only the serving listener");
	} finally {
		await stopServer(proc);
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("a keyed-relay seat registers at a live relay and comes down again", async () => {
	const stateDir = await Deno.makeTempDir();
	const relay = await spawnRelay();
	const proc = spawnAdminServer(stateDir);
	try {
		const port = await readPort(proc);
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const taken = await takeAdmin(session, stateDir);

		const brought = await listenerUp(session, taken.cap, "keyed-relay", { relay: relay.url });
		assert(brought.transport === "keyed-relay" && brought.id !== null, "the keyed-relay seat did not come up");
		assertMatch(brought.locator ?? "", /^ocapn:\/\/.+\.keyed-relay/);
		assert((brought.locator ?? "").includes("rendezvous-relay"), "the relay locator carries no relay route");

		await listenerDown(session, taken.cap, brought.id!);
		const after = await listListeners(session, taken.cap);
		assert(seat(after, "keyed-relay").id === null, "the downed keyed-relay seat is still live");
	} finally {
		await stopServer(proc);
		// The scratch relay is a fixture with nothing to save, and its graceful
		// path lingers on the sockets the downed listener left, so it gets no
		// grace: the polite signal is followed straight away by the hard one.
		await stopOwned(relay.proc, 0);
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("a loopback tcp listener rides up and down at runtime", async () => {
	if (!await irohUsable()) {
		console.log("skipped: this tree cannot run the iroh room server (zig build iroh-abi, cargo required)");
		return;
	}
	// The server holds one live listener per transport, so the tcp round trip
	// runs on a server whose boot listener is iroh: `up("tcp")` then has the
	// tcp seat free, and the brought-up listener serves the same directory.
	const stateDir = await Deno.makeTempDir();
	const proc = spawnOwned("deno", {
		args: [...IROH_FLAGS, SERVER, "--transport=iroh", "--admin-listeners"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: stateDir },
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const uri = await readAnnounce(proc, 20_000);
		const session = await dial(uri);
		session.serve().catch(() => {});
		const taken = await takeAdmin(session, stateDir);
		const iroh = seat(taken.rows, "iroh");
		assert(liveCount(taken.rows) === 1 && iroh.id !== null && iroh.serving, "the iroh boot seat is wrong");

		const brought = await listenerUp(session, taken.cap, "tcp");
		assert(brought.id !== null && !brought.serving, "the new tcp listener claims to be serving");
		assertMatch(brought.locator ?? "", /^127\.0\.0\.1:\d+$/);

		// A member arriving over the brought-up listener reaches the same rooms.
		const overTcp = await dial(brought.locator!);
		overTcp.serve().catch(() => {});
		await overTcp.fetch(DIRECTORY);
		const room = await Room.subscribe(overTcp, await enterOrOpen(overTcp, "via-upped"), "ada");
		await room.leave();

		const two = await listListeners(session, taken.cap);
		assert(liveCount(two) === 2, `expected two live listeners after up: ${JSON.stringify(two)}`);

		// Down it: the seat empties and a fresh dial finds nothing listening.
		await listenerDown(session, taken.cap, brought.id!);
		const one = await listListeners(session, taken.cap);
		assert(liveCount(one) === 1 && seat(one, "iroh").serving, "expected only the serving listener");
		let refused = "";
		try {
			await within(Directory.connect(brought.locator!, (address) => dial(address)), "a refused dial", 5_000);
		} catch (err) {
			refused = err instanceof Error ? err.message : String(err);
		}
		assert(refused !== "", "a downed listener still accepted a dial");
	} finally {
		await stopServer(proc);
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("route advertisement follows each caller's negotiated profile", async () => {
	const stateDir = await Deno.makeTempDir();
	const proc = spawnAdminServer(stateDir);
	try {
		const tcpLocator = loopbackTcpDesignator(await readPort(proc));
		const session = await dial(tcpLocator);
		session.serve().catch(() => {});
		const taken = await takeAdmin(session, stateDir);
		const directory = await session.fetch(DIRECTORY);
		try {
			const noise = await listenerUp(session, taken.cap, "noise-tcp");
			assert(noise.id !== null && noise.locator !== null, "the noise listener did not come up");

			const bundled = await session.send(directory, ADVERTISED_LOCATION, []);
			assert(typeof bundled === "string", "advertisedLocation did not answer a locator");
			const identity = parseLocator(bundled);
			assert(identity.transport === TRANSPORT_ID, "the negotiated route feature did not advertise id/via");
			const via = stringHint(identity, HINT_VIA);
			assert(via === noise.locator, "id/via did not carry the proving Noise route");
			assert(
				stringHint(identity, HINT_ALT_LOCATORS)?.includes(".tcp") === true,
				"id/via omitted the baseline TCP fallback",
			);
			await using routeRuntime = await openRoomsRuntime();
			const byIdentity = await Directory.connect(bundled, (address) => dialDirectory(address, routeRuntime));
			await byIdentity.list();
			await byIdentity.close();
			const routed = await Directory.connect(tcpLocator, (address) => dial(address));
			const routedRoom = await routed.openManaged("routed-link");
			const routedLink = parseRoomsSturdyref(routedRoom.roomLink).locator;
			assert(routedLink.transport === TRANSPORT_ID, "the Host did not put its identity route in a room link");
			assert(
				stringHint(routedLink, HINT_VIA) === noise.locator,
				"the room link did not carry the Host's proving route",
			);
			assert(
				stringHint(routedLink, HINT_ALT_LOCATORS)?.includes(".tcp") === true,
				"the room link omitted the Host's concrete fallback",
			);
			routed.session.release(routedRoom.room);
			await routed.close();

			const nextFloorHost = roomsHost(undefined, "native-baseline");
			const nextFloor = await Directory.connect(tcpLocator, (address) => dial(address, nextFloorHost));
			assert(nextFloor.session.profile.captpVersion === "next", "the next caller fell back to v1.0");
			assert(
				(nextFloor.session.profile.features & FEATURE_MULTI_LOCATION) === 0,
				"the feature-limited caller negotiated multi-location",
			);
			assert(
				await nextFloor.advertisedLocation() === tcpLocator,
				"a next caller without the route feature received id/via",
			);
			const floorRoom = await nextFloor.openManaged("next-floor-link");
			const floorLink = parseRoomsSturdyref(floorRoom.roomLink).locator;
			assert(
				floorLink.transport === TRANSPORT_TCP && floorLink.designator === tcpLocator,
				"the feature-limited caller's room link did not carry its concrete route",
			);
			nextFloor.session.release(floorRoom.room);

			const floorHost = roomsHost(undefined, "interop");
			const floor = await Directory.connect(tcpLocator, (address) => dial(address, floorHost));
			assert(floor.session.profile.captpVersion === "v1_0", "the compatibility caller did not settle v1.0");
			assert(floor.session.profile.codec === "syrup", "the compatibility caller did not settle Syrup");
			assert(
				await floor.advertisedLocation() === tcpLocator,
				"a v1.0 caller received pancake-next route vocabulary",
			);

			const linked = await floor.openManaged("v1-link");
			const sturdyref = linked.roomLink;
			const parsedFloorLink = parseRoomsSturdyref(sturdyref);
			assert(
				parsedFloorLink.locator.transport === TRANSPORT_TCP &&
					parsedFloorLink.locator.designator === tcpLocator,
				"the v1.0 room link did not carry its concrete route",
			);
			const swiss = parsedFloorLink.swissnum;
			const encodedSwiss = sturdyref.match(/\/s\/([^?]+)/)?.[1];
			const expectedSwiss = btoa(String.fromCharCode(...swiss))
				.replaceAll("+", "-")
				.replaceAll("/", "_")
				.replace(/=+$/, "");
			assert(encodedSwiss === expectedSwiss, "the v1.0 link did not use unpadded base64url swiss encoding");
			floor.session.release(linked.room);
			await floor.close();
			await nextFloor.close();

			await listenerDown(session, taken.cap, noise.id);
			assert(
				await session.send(directory, ADVERTISED_LOCATION, []) === tcpLocator,
				"one remaining listener did not collapse to its concrete locator",
			);
		} finally {
			session.release(directory);
		}
	} finally {
		await stopServer(proc);
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("no listener capability exists without the flag", async () => {
	const stateDir = await Deno.makeTempDir();
	// First run mints and persists the swiss; the second run, without the flag,
	// must leave that name answering nothing — not minted, not published.
	let proc = spawnAdminServer(stateDir);
	let swiss = "";
	try {
		await readPort(proc);
		swiss = (await Deno.readTextFile(`${stateDir}/admin-listeners`)).trim();
		assert(swiss.length > 0, "the flagged server did not write a listeners swiss");
	} finally {
		await stopServer(proc);
	}
	proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: stateDir },
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const port = await readPort(proc);
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		// The directory still answers, so the refusal below is about the swiss.
		await session.fetch(DIRECTORY);
		let refused = "";
		try {
			await within(session.fetch(swiss), "the unpublished swiss to be refused", 5_000);
		} catch (err) {
			refused = err instanceof Error ? err.message : String(err);
		}
		assert(refused !== "", "an unflagged server answered the listeners swiss");
	} finally {
		await stopServer(proc);
		await Deno.remove(stateDir, { recursive: true });
	}
});
