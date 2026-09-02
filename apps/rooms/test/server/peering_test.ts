import {
	formatLocatorUri,
	HINT_ALT_LOCATORS,
	HINT_VIA,
	parseLocator,
	Ref,
	stringHint,
	TRANSPORT_ID,
} from "@glowcap/runtime";
import { loopbackTcpDesignator, parseRoomsSturdyref, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { PUBLICATION_READY, PUBLISH_DURABLE_ROOM, REVOKE } from "../../lib/protocol.ts";
import { Directory, DirectoryPeering, listenerUp, Room, takeListeners } from "../../lib/room/client.ts";
import {
	assert,
	DENO_FLAGS,
	dial,
	IROH_FLAGS,
	irohUsable,
	readAnnounce,
	readPort,
	roomsTest,
	ROOT,
	SERVER,
	stopServer,
	waitForMatch,
	withPeeringServer,
	withServer,
} from "../support/rooms_server.ts";
import { spawnOwned } from "../support/children.ts";

async function openManagedRoom(source: Directory, name: string): Promise<Room> {
	const managed = await source.openManaged(name);
	const room = await Room.subscribe(source.session, managed.room, "owner");
	await room.takeManager(managed.managerLink);
	return room;
}

roomsTest("peering redeems an identity-routed room through its weak TCP fallback", async () => {
	if (!await irohUsable()) {
		console.log("skipped: this tree cannot run the iroh room server (zig build iroh-abi, cargo required)");
		return;
	}
	const sourceState = await Deno.makeTempDir();
	const sourceProc = spawnOwned("deno", {
		args: [...IROH_FLAGS, SERVER, "--transport=iroh", "--admin-listeners"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), GLOWCAP_ROOMS_STATE: sourceState },
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const irohLocator = await readAnnounce(sourceProc, 20_000);
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const publisherHost = roomsHost();
			const connect = (locator: string) => Directory.connect(locator, (address) => dial(address, publisherHost));
			const source = await connect(irohLocator);
			const adminSwiss = (await Deno.readTextFile(`${sourceState}/admin-listeners`)).trim();
			const admin = await takeListeners(source.session, adminSwiss);
			const tcp = await listenerUp(source.session, admin.cap, "tcp");
			assert(tcp.locator !== null, "the source did not publish its TCP fallback");

			const advertised = parseLocator(await source.advertisedLocation());
			assert(advertised.transport === TRANSPORT_ID, "the source did not advertise one identity route");
			assert(stringHint(advertised, HINT_VIA)?.includes(irohLocator), "the identity route omitted iroh");
			assert(
				stringHint(advertised, HINT_ALT_LOCATORS)?.includes(formatLocatorUri(roomsLocator(tcp.locator))),
				"the identity route omitted its TCP fallback",
			);

			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const viewer = await Directory.connect(
				loopbackTcpDesignator(destinationPort),
				(address) => dial(address, roomsHost()),
			);
			const room = await openManagedRoom(source, "routed");
			const roomRoute = parseRoomsSturdyref(await room.link()).locator;
			assert(roomRoute.transport === TRANSPORT_ID, "the room link did not carry the identity route");
			assert(
				stringHint(roomRoute, HINT_ALT_LOCATORS)?.includes(formatLocatorUri(roomsLocator(tcp.locator))),
				"the room link omitted its TCP fallback",
			);
			const peering = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await peering.publish("routed", room, source);
			const listed = (await viewer.list())[0];
			assert(listed?.kind === "foreign", "the routed room was not published at the destination");
			const visitor = await Room.subscribe(viewer.session, await viewer.enterPublication(listed.id), "visitor");
			await visitor.say("reached over fallback");

			await publication.revoke();
			await visitor.leave();
			await room.leave();
			await peering.close();
			source.session.release(admin.cap);
			await viewer.close();
			await publisher.close();
			await source.close();
		});
	} finally {
		await stopServer(sourceProc);
		await Deno.remove(sourceState, { recursive: true });
	}
});

roomsTest("peering publishes one durable foreign room and revocation leaves handed capabilities live", async () => {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const publisherHost = roomsHost();
			const connect = (locator: string) => Directory.connect(locator, (address) => dial(address, publisherHost));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const viewer = await Directory.connect(
				loopbackTcpDesignator(destinationPort),
				(address) => dial(address, roomsHost()),
			);
			const room = await openManagedRoom(source, "federated");
			const events: { kind: string; id: string; count: number | null }[] = [];
			await viewer.watch((event) => {
				if (event.entry !== null) events.push({ kind: event.kind, id: event.entry.id, count: event.count });
			});
			const peering = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await peering.publish("federated", room, source);
			const listed = await viewer.list();
			assert(listed.length === 1, `expected one peered room, got ${JSON.stringify(listed)}`);
			const entry = listed[0];
			assert(entry.kind === "foreign", "the peered room was listed as local");
			assert(entry.count === null, "foreign occupancy was invented");
			assert(entry.proof === "session", `plain TCP claimed ${entry.proof} origin proof`);
			assert(
				events.some((event) => event.kind === "opened" && event.id === entry.id && event.count === null),
				"the watch delta did not carry the exact foreign publication",
			);

			const handed = await viewer.enterPublication(entry.id);
			const visitor = await Room.subscribe(viewer.session, handed, "visitor");
			await publication.revoke();
			assert((await viewer.list()).length === 0, "revocation left the foreign room discoverable");
			assert(
				events.some((event) => event.kind === "closed" && event.id === entry.id && event.count === null),
				"the close delta did not retire the exact publication",
			);

			// Revocation removes discovery, not authority already handed out.
			await room.leave();
			await visitor.say("still reachable");
			await visitor.leave();

			await peering.close();
			await viewer.close();
			await publisher.close();
			await source.close();
		});
	});
});

roomsTest("releasing a publication lease does not revoke before publisher disconnect", async () => {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const host = roomsHost();
			const connect = (locator: string, on = host) => Directory.connect(locator, (address) => dial(address, on));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const observer = await connect(loopbackTcpDesignator(destinationPort), roomsHost());
			const room = await openManagedRoom(source, "leased");
			const peering = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await peering.publish("leased", room, source);

			publication.release();
			await peering.close();
			assert((await observer.list()).length === 1, "releasing the lease silently revoked its listing");
			await publisher.close();
			await waitForMatch(async () => String((await observer.list()).length), /^0$/);

			await room.leave();
			await observer.close();
			await source.close();
		});
	});
});

roomsTest("closing peering cancels a publication already admitted by the client", async () => {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const host = roomsHost();
			const connect = (locator: string) => Directory.connect(locator, (address) => dial(address, host));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const room = await openManagedRoom(source, "cancelled");
			const first = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const pending = first.publish("reusable", room, source);
			await first.close();
			let cancelled = false;
			try {
				await pending;
			} catch {
				cancelled = true;
			}
			assert(cancelled, "close let its in-flight publication become live");

			const second = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await second.publish("reusable", room, source);
			assert((await publisher.list())[0]?.name === "reusable", "close left the admitted name occupied");

			await publication.revoke();
			await second.close();
			await room.leave();
			await publisher.close();
			await source.close();
		});
	});
});

roomsTest("stale peering leases cannot revoke replacements and publisher disconnect cleans its rooms", async () => {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const host = roomsHost();
			const connect = (locator: string, on = host) => Directory.connect(locator, (address) => dial(address, on));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const observer = await connect(loopbackTcpDesignator(destinationPort), roomsHost());
			const room = await openManagedRoom(source, "replaceable");
			await room.link();
			const authority = await publisher.session.fetch(peeringSwiss);
			const publish = async (): Promise<Ref> => {
				const lease = await publisher.session.send(authority, PUBLISH_DURABLE_ROOM, [
					"replaceable",
					room.reference,
				]);
				assert(lease instanceof Ref, "publishing did not return a lease");
				await publisher.session.send(lease, PUBLICATION_READY, []);
				return lease;
			};

			const firstLease = await publish();
			const first = (await publisher.list())[0];
			assert(first !== undefined, "the first publication was not listed");
			let refused = false;
			try {
				await publisher.session.send(firstLease, PUBLICATION_READY, ["surplus"]);
			} catch {
				refused = true;
			}
			assert(refused, "a publication lease accepted surplus readiness data");
			assert((await publisher.list())[0]?.id === first.id, "a malformed lease call changed the publication");
			await publisher.session.send(firstLease, REVOKE, []);
			const secondLease = await publish();
			const second = (await publisher.list())[0];
			assert(second !== undefined && second.id !== first.id, "replacement reused a publication identity");
			await publisher.session.send(firstLease, REVOKE, []);
			assert((await publisher.list())[0]?.id === second.id, "a stale lease revoked its replacement");
			let staleEntered = false;
			try {
				await publisher.enterPublication(first.id);
				staleEntered = true;
			} catch {
				// Exact entry must fail once that generation is gone.
			}
			assert(!staleEntered, "an exact enter silently followed a room name to its replacement");

			publisher.session.release(firstLease);
			publisher.session.release(secondLease);
			publisher.session.release(authority);
			await publisher.close();
			await waitForMatch(async () => String((await observer.list()).length), /^0$/);

			await room.leave();
			await observer.close();
			await source.close();
		});
	});
});

roomsTest("a synchronous peering listen refusal releases the reservation immediately", async () => {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const host = roomsHost();
			const connect = (locator: string) => Directory.connect(locator, (address) => dial(address, host));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const authority = await publisher.session.fetch(peeringSwiss);

			// Sending the destination's own live peering object back to it produces
			// a near object, not the far promise glowcap-next listen requires. The
			// refusal happens synchronously while the server admits listen.
			let refused = false;
			try {
				await publisher.session.send(authority, PUBLISH_DURABLE_ROOM, ["reusable", authority]);
			} catch {
				refused = true;
			}
			assert(refused, "peering accepted a live object where a handed promise was required");

			// The failed transaction must have returned its name and quota slot now,
			// rather than waiting for the handed-room deadline or disconnect cleanup.
			const room = await openManagedRoom(source, "source");
			const peering = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await peering.publish("reusable", room, source);
			assert((await publisher.list())[0]?.name === "reusable", "the refused reservation was not reusable");

			await publication.revoke();
			await peering.close();
			publisher.session.release(authority);
			await room.leave();
			await publisher.close();
			await source.close();
		});
	});
});

roomsTest("no peering capability exists without the flag", async () => {
	const state = await Deno.makeTempDir();
	let proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0", "--peering"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), GLOWCAP_ROOMS_STATE: state },
		stdout: "piped",
		stderr: "piped",
	});
	let swiss = "";
	try {
		await readPort(proc);
		swiss = (await Deno.readTextFile(`${state}/peering`)).trim();
		assert(swiss.length > 0, "the flagged server did not write a peering swiss");
	} finally {
		await stopServer(proc);
	}

	proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), GLOWCAP_ROOMS_STATE: state },
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const directory = await Directory.connect(
			loopbackTcpDesignator(await readPort(proc)),
			(address) => dial(address),
		);
		let refused = false;
		try {
			await directory.session.fetch(swiss);
		} catch {
			refused = true;
		}
		assert(refused, "an unflagged server answered the persisted peering swiss");
		await directory.close();
	} finally {
		await stopServer(proc);
		await Deno.remove(state, { recursive: true });
	}
});
