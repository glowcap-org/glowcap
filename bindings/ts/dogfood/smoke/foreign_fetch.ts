import * as tcp from "@pancake/tcp";
import { FetchFailed, type Runtime } from "../../runtime/mod.ts";
import { assert, ok, startRelay } from "./support.ts";

/** Prove a foreign bootstrap answer that is not a capability fails typed. */
export async function runForeignFetch(managed: Runtime): Promise<void> {
	const server = await tcp.listen("127.0.0.1", 0);
	const targetPort = server.port;
	let plainExport = -1n;
	let exportReady!: () => void;
	const exportKnown = new Promise<void>((resolve) => (exportReady = resolve));

	// Replace the first `desc:export0+` with `desc:export<P>+`. The spliced
	// integer is whatever position the host allocated, which is not necessarily
	// the same width, so rebuild the whole delimiter-terminated Syrup frame.
	// Arm only after the legitimate fetch grants the export; the doctored fetch
	// must exercise reply typing, not probe an ungranted position.
	let armed = false;
	let retargeted = false;
	let capturing = false;
	let observedWire = "";
	let pending = new Uint8Array();
	const decoder = new TextDecoder();
	const encoder = new TextEncoder();
	function observe(chunk: Uint8Array, toServer: boolean): void {
		if (toServer || !capturing || plainExport >= 0n) return;
		observedWire += decoder.decode(chunk, { stream: true });
		const match = /desc:import-object(\d+)\+/.exec(observedWire);
		if (match !== null) plainExport = BigInt(match[1]);
	}
	function retarget(chunk: Uint8Array): Uint8Array {
		if (!armed || plainExport < 0n) return chunk;
		if (retargeted && pending.length === 0) return chunk;
		const joined = new Uint8Array(pending.length + chunk.length);
		joined.set(pending);
		joined.set(chunk, pending.length);
		pending = joined;

		const frames: Uint8Array[] = [];
		while (pending.length > 0) {
			let colon = -1;
			let bodyLength = 0;
			for (let i = 0; i < pending.length; i++) {
				const byte = pending[i];
				if (byte === 58) {
					colon = i;
					break;
				}
				if (byte < 48 || byte > 57) {
					const malformed = pending;
					pending = new Uint8Array();
					return malformed;
				}
				bodyLength = bodyLength * 10 + byte - 48;
			}
			if (colon < 0 || pending.length < colon + 1 + bodyLength) break;

			const frameEnd = colon + 1 + bodyLength;
			let body = pending.slice(colon + 1, frameEnd);
			pending = pending.slice(frameEnd);
			if (!retargeted) {
				const needle = encoder.encode("desc:export0+");
				outer: for (let i = 0; i + needle.length <= body.length; i++) {
					for (let j = 0; j < needle.length; j++) {
						if (body[i + j] !== needle[j]) continue outer;
					}
					const replacement = encoder.encode(`desc:export${plainExport}+`);
					const spliced = new Uint8Array(body.length - needle.length + replacement.length);
					spliced.set(body.subarray(0, i));
					spliced.set(replacement, i);
					spliced.set(body.subarray(i + needle.length), i + replacement.length);
					body = spliced;
					retargeted = true;
					break;
				}
			}
			const prefix = encoder.encode(`${body.length}:`);
			const frame = new Uint8Array(prefix.length + body.length);
			frame.set(prefix);
			frame.set(body, prefix.length);
			frames.push(frame);
		}

		const size = frames.reduce((total, frame) => total + frame.length, 0);
		const output = new Uint8Array(size);
		let offset = 0;
		for (const frame of frames) {
			output.set(frame, offset);
			offset += frame.length;
		}
		return output;
	}
	const relay = await startRelay(targetPort, retarget, observe);

	async function host(): Promise<void> {
		for await (const session of server) {
			// The doctored fetch deliver lands here with verb "fetch"; answer with
			// a plain integer, exactly what a fetch must not resolve to.
			session.publish("plain", () => 42n);
			exportReady();
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await managed.connect(tcp.locator("127.0.0.1", relay.port));
		session.serve().catch(() => {});
		await exportKnown;
		capturing = true;
		await session.fetch("plain");
		for (let i = 0; i < 100 && plainExport < 0n; i++) await Promise.resolve();
		assert(plainExport >= 0n, "the granting fetch exposed no import-object descriptor");
		capturing = false;
		armed = true;
		let failed: FetchFailed | null = null;
		try {
			await session.fetch("not-a-capability");
		} catch (error) {
			if (error instanceof FetchFailed) failed = error;
		}
		assert(failed !== null, "a non-capability fetch rejects with FetchFailed");
		assert(
			failed.capabilityName === "not-a-capability",
			`FetchFailed names the capability, got ${failed.capabilityName}`,
		);
		await session.close();
	}

	await Promise.all([client(), hosted]);
	relay.close();
	ok("a non-capability fetch rejects with the typed FetchFailed");
}
