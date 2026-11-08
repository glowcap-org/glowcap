// The published page, with no Rooms server, reaches a directory through a door
// this browser opens by itself, and says which door when it cannot.
//
// A directory with a declared `noise-relay` listener is named by its key, with
// the sealed relay door first. The static page dials that door straight from
// the browser, so the address is reached with no server and no allowed
// origin, the server ask never appears, and the directory's card says the
// route the connection took. When the relay does not answer, the page names
// it: alone, as the refusal on the join card, and beside a door only a Rooms
// server reaches, as the reason the page asks for one.

import { formatLocatorUri, parseLocator, TRANSPORT_NOISE_RELAY } from "@glowcap/runtime";
import type { Browser, Page } from "playwright";
import { nonEphemeralPort } from "../../../../bindings/ts/test/ports.ts";
import { HINT_RENDEZVOUS_RELAY } from "../../lib/doors.ts";
import { roomsIdentityDoors, roomsIdentityRoute } from "../../lib/routes.ts";
import { routeRelay } from "../../lib/text/directory.ts";
import { doorUnreachable } from "../../lib/text/failure.ts";
import { serverAskAfterDoor } from "../../lib/text/session.ts";
import { stopOwned } from "../support/children.ts";
import { fail } from "../support/fail.ts";
import { ROOT } from "../support/paths.ts";
import { roomLocator } from "../support/rooms_server.ts";
import { establishLocalSession } from "../support/session_setup.ts";
import { serveStaticExport } from "../support/static_host.ts";
import { spawnWeb, webPort } from "../support/web_front.ts";
import { fillSettled, openDirectoryCard, reachDirectoryOnCard } from "./harness.ts";

export async function run(browser: Browser): Promise<void> {
	// Its own front and room, so the only thing the page shares with the server
	// it reaches is the door that server declared.
	const front = spawnWeb({
		args: ["--transport=tcp", "0", "0", "--listen=noise-relay"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "inherit",
	});
	const host = await serveStaticExport();
	const bare = await browser.newContext();
	try {
		const address = await roomLocator(await webPort(front), "the front with a relay door");
		const open = await bare.newPage();
		await open.goto(`${host.origin}/`);
		await establishLocalSession(open);
		await fillSettled(open, "#locator", address);
		await fillSettled(open, "#nick", "door");
		if (await reachDirectoryOnCard(open, "garden") === "question") {
			await fillSettled(open, "#room", "garden");
			await open.click("#joinBtn");
		}
		await open.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
			.catch(async () =>
				fail(
					"the published page did not reach a directory through its relay door: " +
						JSON.stringify({
							refused: await open.textContent("#joinError").catch(() => null),
							asked: await open.locator("#serverAddress").count(),
						}),
				)
			);
		if (await open.locator("#serverAddress").count() !== 0) {
			fail("reaching a directory through a door the browser opens itself asked for a Rooms server");
		}
		// The room's card names its directory, and that directory's card says
		// the route.
		await open.click("#roomAbout");
		await open.click("#convcardDir", { timeout: 10_000 });
		await open.waitForFunction(() => location.pathname === "/directory", { timeout: 10_000 }).catch(() =>
			fail("the directory named on the room's card did not open that directory")
		);
		await openDirectoryCard(open);
		await open.waitForFunction(
			(route) => document.getElementById("dirfactRoute")?.textContent === route,
			routeRelay,
			{ timeout: 10_000 },
		).catch(async () =>
			fail(
				`the directory's card did not say it is reached through the relay: ${
					JSON.stringify(await open.textContent(".modal .dirfacts").catch(() => null))
				}`,
			)
		);
		await deadDoorsAreNamed(await bare.newPage(), host.origin, address);
	} finally {
		await bare.close();
		await host.close();
		await stopOwned(front);
	}
}

/** The same directory's address with its relay door moved to a port nothing
 * listens on: alone, the join card names the relay, and beside the TCP door,
 * the page asks for a Rooms server and says the relay is why. */
async function deadDoorsAreNamed(open: Page, origin: string, address: string): Promise<void> {
	const route = parseLocator(address);
	const doors = roomsIdentityDoors(route);
	const relay = doors.find((door) => door.transport === TRANSPORT_NOISE_RELAY);
	const other = doors.find((door) => door.transport !== TRANSPORT_NOISE_RELAY);
	if (relay == null || other == null) fail(`the front's address did not list a relay door and another: ${address}`);
	const silent = `127.0.0.1:${nonEphemeralPort()}`;
	const dead = formatLocatorUri({ ...relay, hints: new Map([[HINT_RENDEZVOUS_RELAY, `ws://${silent}/relay`]]) });
	const said = doorUnreachable(silent, "");
	await open.goto(`${origin}/`);
	await establishLocalSession(open);
	await fillSettled(open, "#nick", "door");
	// The relay door alone: the refusal stays on the card and names the relay.
	await fillSettled(open, "#locator", dead);
	await open.click("#joinBtn");
	await open.waitForFunction(
		(said) => (document.getElementById("joinError")?.textContent ?? "").startsWith(said),
		said,
		{ timeout: 30_000 },
	).catch(async () =>
		fail(
			"a relay door nothing answers at was not named on the join card: " +
				JSON.stringify(await open.textContent("#joinError").catch(() => null)),
		)
	);
	if (await open.locator("#serverAddress").count() !== 0) {
		fail("an address with only a door this browser opens itself asked for a Rooms server");
	}
	// The relay door beside the TCP door: the page asks for a server, and the
	// ask says the relay did not answer.
	const mixed = roomsIdentityRoute(route.designator, [dead, formatLocatorUri(other)]);
	if (mixed == null) fail("a relay door and a TCP door did not make an identity route");
	await fillSettled(open, "#locator", formatLocatorUri(mixed));
	await open.click("#joinBtn");
	const lead = open.locator('dialog[aria-labelledby="serverAskTitle"] .lead');
	await lead.waitFor({ state: "visible", timeout: 30_000 }).catch(async () =>
		fail(
			"an address with a door only a server reaches did not ask for one: " +
				JSON.stringify(await open.textContent("#joinError").catch(() => null)),
		)
	);
	// The dial reports whichever door failed last, so the break's own words
	// may or may not ride along; the relay and the way in are said either way.
	const asked = (await lead.textContent()) ?? "";
	if (!asked.startsWith(said) || !asked.endsWith(serverAskAfterDoor("").trim())) {
		fail(`the ask did not say the relay is why: ${JSON.stringify(asked)}`);
	}
}
