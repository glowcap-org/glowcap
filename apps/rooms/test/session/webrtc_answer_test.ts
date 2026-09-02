// Hosted webrtc membership files the directory signaling inbox Attach dials.

import { formatPeerUri, type Host, TRANSPORT_WEBRTC } from "@glowcap/runtime";
import { NICK_TAKEN, PEER_OFFLINE, roomErrorOf } from "../../lib/errors.ts";
import { loopbackTcpDesignator, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { Directory } from "../../lib/room/client.ts";
import { answerWebrtcSignaling } from "../../session/webrtc_answer.ts";
import { assertEquals } from "../assert.ts";
import { delay, dial, roomsTest, withServer } from "../support/rooms_server.ts";

Deno.test("a TCP member locator does not start WebRTC answering", async () => {
	assertEquals(
		await answerWebrtcSignaling({
			host: {} as Host,
			directory: {} as Directory,
			memberLocator: "127.0.0.1:9",
			onError: () => {},
		}),
		null,
	);
});

roomsTest("registering a webrtc locator without an inbox is peer-offline until answering files one", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const host = roomsHost();
		const memberLocator = formatPeerUri(TRANSPORT_WEBRTC, host.designator());
		const designator = roomsLocator(memberLocator).designator;
		const directory = await Directory.connect(locator, (address) => dial(address, host));
		const origin = await Directory.connect(locator, (address) => dial(address));
		let signaling: { close(): Promise<void> } | null = null;
		try {
			await origin.register("origin", locator);
			await directory.register("host", memberLocator);
			let refused = "";
			try {
				await origin.signalOffer(designator, "offer-sdp");
			} catch (error) {
				refused = roomErrorOf(error)?.code ?? "";
			}
			assertEquals(refused, PEER_OFFLINE);

			signaling = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			assertEquals(signaling != null, true);

			const retry = await Directory.connect(locator, (address) => dial(address));
			try {
				await retry.register("retry", locator);
				const pending = retry.signalOffer(designator, "offer-sdp");
				const raced = await Promise.race([
					pending.then(
						() => "answered",
						(error) =>
							roomErrorOf(error)?.detail ?? (error instanceof Error ? error.message : String(error)),
					),
					delay(80).then(() => "waiting"),
				]);
				assertEquals(
					typeof raced === "string" && !raced.includes("no signaling inbox") && raced !== PEER_OFFLINE,
					true,
					`signalOffer after answering: ${raced}`,
				);
			} finally {
				await retry.close();
			}
		} finally {
			await signaling?.close();
			await origin.close();
			await directory.close();
		}
	});
});

roomsTest("closing the WebRTC answering inbox without replacing it leaves offers unanswered", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const host = roomsHost();
		const memberLocator = formatPeerUri(TRANSPORT_WEBRTC, host.designator());
		const designator = roomsLocator(memberLocator).designator;
		const directory = await Directory.connect(locator, (address) => dial(address, host));
		const origin = await Directory.connect(locator, (address) => dial(address));
		let signaling: { close(): Promise<void> } | null = null;
		try {
			await origin.register("origin", locator);
			await directory.register("host", memberLocator);
			signaling = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			await signaling?.close();
			const retry = await Directory.connect(locator, (address) => dial(address));
			try {
				await retry.register("retry", locator);
				const pending = retry.signalOffer(designator, "offer-sdp");
				const raced = await Promise.race([
					pending.then(() => "answered", () => "refused"),
					delay(80).then(() => "waiting"),
				]);
				assertEquals(raced !== "answered", true, `a closed answering inbox still answered: ${raced}`);
			} finally {
				await retry.close();
			}
		} finally {
			await origin.close();
			await directory.close();
		}
	});
});

roomsTest("replacing the WebRTC answering inbox then closing the replacement leaves offers unanswered", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const host = roomsHost();
		const memberLocator = formatPeerUri(TRANSPORT_WEBRTC, host.designator());
		const designator = roomsLocator(memberLocator).designator;
		const directory = await Directory.connect(locator, (address) => dial(address, host));
		const origin = await Directory.connect(locator, (address) => dial(address));
		let first: { close(): Promise<void> } | null = null;
		let second: { close(): Promise<void> } | null = null;
		try {
			await origin.register("origin", locator);
			await directory.register("host", memberLocator);
			first = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			second = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			await second?.close();
			const retry = await Directory.connect(locator, (address) => dial(address));
			try {
				await retry.register("retry", locator);
				const pending = retry.signalOffer(designator, "offer-sdp");
				const raced = await Promise.race([
					pending.then(() => "answered", () => "refused"),
					delay(80).then(() => "waiting"),
				]);
				assertEquals(raced !== "answered", true, `a replaced-then-closed inbox still answered: ${raced}`);
			} finally {
				await retry.close();
			}
		} finally {
			await first?.close();
			await origin.close();
			await directory.close();
		}
	});
});

roomsTest("re-registering on the same directory session keeps a WebRTC signaling inbox", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const host = roomsHost();
		const memberLocator = formatPeerUri(TRANSPORT_WEBRTC, host.designator());
		const designator = roomsLocator(memberLocator).designator;
		const directory = await Directory.connect(locator, (address) => dial(address, host));
		const origin = await Directory.connect(locator, (address) => dial(address));
		let first: { close(): Promise<void> } | null = null;
		let second: { close(): Promise<void> } | null = null;
		try {
			await origin.register("origin", locator);
			await directory.register("host", memberLocator);
			first = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			await directory.register("host", memberLocator);
			second = await answerWebrtcSignaling({
				host,
				directory,
				memberLocator,
				iceServers: () => Promise.resolve([]),
				onError: () => {},
			});
			const retry = await Directory.connect(locator, (address) => dial(address));
			try {
				await retry.register("retry", locator);
				const pending = retry.signalOffer(designator, "offer-sdp");
				const raced = await Promise.race([
					pending.then(
						() => "answered",
						(error) =>
							roomErrorOf(error)?.detail ?? (error instanceof Error ? error.message : String(error)),
					),
					delay(80).then(() => "waiting"),
				]);
				assertEquals(
					typeof raced === "string" && !raced.includes("no signaling inbox") && raced !== PEER_OFFLINE,
					true,
					`signalOffer after re-register: ${raced}`,
				);
			} finally {
				await retry.close();
			}
		} finally {
			await second?.close();
			await first?.close();
			await origin.close();
			await directory.close();
		}
	});
});

roomsTest(
	"re-registering under a nick another member holds is nick-taken; the granted nick files signaling",
	async () => {
		await withServer(async (port) => {
			const locator = loopbackTcpDesignator(port);
			const host = roomsHost();
			const memberLocator = formatPeerUri(TRANSPORT_WEBRTC, host.designator());
			const designator = roomsLocator(memberLocator).designator;
			const directory = await Directory.connect(locator, (address) => dial(address, host));
			const origin = await Directory.connect(locator, (address) => dial(address));
			let first: { close(): Promise<void> } | null = null;
			let second: { close(): Promise<void> } | null = null;
			try {
				await origin.register("ada", locator);
				await directory.register("ada2", memberLocator);
				first = await answerWebrtcSignaling({
					host,
					directory,
					memberLocator,
					iceServers: () => Promise.resolve([]),
					onError: () => {},
				});
				let refused = "";
				try {
					await directory.register("ada", memberLocator);
				} catch (error) {
					refused = roomErrorOf(error)?.code ?? "";
				}
				assertEquals(refused, NICK_TAKEN);

				await directory.register("ada2", memberLocator);
				second = await answerWebrtcSignaling({
					host,
					directory,
					memberLocator,
					iceServers: () => Promise.resolve([]),
					onError: () => {},
				});
				const retry = await Directory.connect(locator, (address) => dial(address));
				try {
					await retry.register("retry", locator);
					const pending = retry.signalOffer(designator, "offer-sdp");
					const raced = await Promise.race([
						pending.then(
							() => "answered",
							(error) =>
								roomErrorOf(error)?.detail ?? (error instanceof Error ? error.message : String(error)),
						),
						delay(80).then(() => "waiting"),
					]);
					assertEquals(
						typeof raced === "string" && !raced.includes("no signaling inbox") && raced !== PEER_OFFLINE,
						true,
						`signalOffer after granted-nick re-register: ${raced}`,
					);
				} finally {
					await retry.close();
				}
			} finally {
				await second?.close();
				await first?.close();
				await origin.close();
				await directory.close();
			}
		});
	},
);
