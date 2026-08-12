// The Rooms application over the standardized onion netlayer.
//
// One transport-empty native driver loop hosts the real Rooms directory while
// two independent dial-only loops join it and prove the existing all-to-all
// broadcast. Product composition installs the onion provider explicitly; the
// generic driver and binding remain unaware of concrete transports.

import { formatPeerUri, type Session } from "@pancake/stack";
import { DriverListener, DriverLoop } from "@pancake/stack/driver_loop";
import { installProvider } from "@pancake/stack/transport/onion";
import { type RoomsDial, runClient } from "../clients/deno/client.ts";
import { roomsHost } from "../lib/locator.ts";
import { serveDirectory } from "../server/main.ts";

const TRANSPORT_ONION = "onion";
const DIRECTORY_PUBLISH_BUDGET_MS = 240_000;
const HANDSHAKE_BUDGET_MS = 120_000;

function requiredEnv(name: string): string {
	const value = Deno.env.get(name)?.trim();
	if (!value) throw new Error(`${name} is required`);
	return value;
}

const socks = requiredEnv("PANCAKE_ONION_SOCKS");
const control = requiredEnv("PANCAKE_ONION_CONTROL");

function openLoop(controlEndpoint?: string): DriverLoop {
	const loop = DriverLoop.takeHost(roomsHost(), {
		handshakeMs: HANDSHAKE_BUDGET_MS,
		settleMs: HANDSHAKE_BUDGET_MS,
	});
	try {
		installProvider(loop, { socks, control: controlEndpoint });
		return loop;
	} catch (error) {
		void loop.close();
		throw error;
	}
}

function onionDial(): RoomsDial {
	return async (locator: string): Promise<Session> => {
		const loop = openLoop();
		loop.start();
		const deadline = Date.now() + DIRECTORY_PUBLISH_BUDGET_MS;
		while (true) {
			try {
				const session = await loop.connectSession(locator);
				session.ownsHost = true;
				return session;
			} catch (error) {
				if (Date.now() >= deadline) {
					await loop.close();
					throw error;
				}
				await new Promise((resolve) => setTimeout(resolve, 2_000));
			}
		}
	};
}

const serverLoop = openLoop(control);
const listener = DriverListener.open(serverLoop, TRANSPORT_ONION, "");
const published = listener.locator();
if (published.hints.size !== 0) {
	listener.close();
	await serverLoop.close();
	throw new Error("onion listener published direct-address hints");
}
listener.select();
serverLoop.start();
const locator = formatPeerUri(TRANSPORT_ONION, published.designator);

const accepted = {
	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		while (true) {
			const session = await listener.accept();
			if (session == null) return;
			yield session;
		}
	},
};
const serving = serveDirectory(accepted);

const roster = ["onion-ada", "onion-grace"];
console.log(`rooms onion demo: server at ${locator}`);
try {
	const transcripts = await Promise.all(roster.map((nick) =>
		runClient(
			locator,
			"onion-demo",
			nick,
			`hello from ${nick}`,
			roster,
			HANDSHAKE_BUDGET_MS,
			onionDial(),
		)
	));
	for (const [index, transcript] of transcripts.entries()) {
		if (transcript.length !== roster.length) {
			throw new Error(
				`${roster[index]} received ${transcript.length}/${roster.length} lines`,
			);
		}
	}
	console.log("rooms onion demo OK: two independent peers exchanged every room message over Tor");
} finally {
	listener.close();
	try {
		await serving;
	} finally {
		await serverLoop.requestClose();
	}
}
