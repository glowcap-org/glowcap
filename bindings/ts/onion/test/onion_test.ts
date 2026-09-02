// The onion transport surface, driven against a fake Tor daemon.
//
// Nothing here needs Tor or the network. Two loopback servers stand in for the
// daemon's control and SOCKS endpoints, answering the exact requests glowcap
// sends. The bytes those requests must contain are pinned on the Zig side, in
// `test/net/onion_socks5_test.zig` and `test/net/onion_control_test.zig`, against
// the pinned Spritely Goblins netlayer and the upstream OCapN suite; this file
// proves the TypeScript surface reaches them and reads the answers back.

// Local assertions rather than an external assert package: this scope takes no
// inline dependency specifiers, and its sibling tests do the same.
function assertThrows(fn: () => unknown): void {
	try {
		fn();
	} catch {
		return;
	}
	throw new Error("expected the call to throw");
}
import { DriverLoop, GlowcapError } from "@glowcap/runtime/transport";
import { Connection, installProvider, listen, Netlayer, SERVICE_ID_LENGTH } from "../mod.ts";
import { assert, assertDeepEquals, assertRejects } from "../../dogfood/assert.ts";

/** A real, checksum-valid version 3 id, from the pinned Goblins source. Using a
 * well-formed one matters: the transport refuses anything else before it opens a
 * socket, so a placeholder would pass for the wrong reason. */
const SERVICE_ID = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";
const SERVICE_KEY = "ED25519-V3:c3RvcmVk";

interface Fake {
	address: string;
	close(): void;
	/** Resolves with the `AUTHENTICATE` line the daemon received. */
	authenticate: Promise<string>;
}

/** A fake control endpoint: answers `AUTHENTICATE`, then `ADD_ONION`, and reports
 * which credential form it was sent.
 *
 * Reporting the credential is not incidental. Every other test here uses an
 * unauthenticated endpoint, where a mapping that sent no credential at all would
 * look exactly like success. */
function fakeControl(): Fake {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const address = `127.0.0.1:${(listener.addr as Deno.NetAddr).port}`;
	let report: (line: string) => void = () => {};
	const authenticate = new Promise<string>((resolve) => {
		report = resolve;
	});

	(async () => {
		for await (const conn of listener) {
			(async () => {
				const decoder = new TextDecoder();
				const encoder = new TextEncoder();
				let pending = "";
				let seen = false;
				const buf = new Uint8Array(1024);
				while (true) {
					let n: number | null;
					try {
						n = await conn.read(buf);
					} catch {
						break;
					}
					if (n === null) break;
					pending += decoder.decode(buf.subarray(0, n));
					let cut: number;
					while ((cut = pending.indexOf("\n")) >= 0) {
						const line = pending.slice(0, cut).replace(/\r$/, "");
						pending = pending.slice(cut + 1);
						if (line.startsWith("AUTHENTICATE") && !seen) {
							seen = true;
							report(line);
						}
						const reply = line.startsWith("ADD_ONION")
							? `250-ServiceID=${SERVICE_ID}\r\n250-PrivateKey=${SERVICE_KEY}\r\n250 OK\r\n`
							: "250 OK\r\n";
						try {
							await conn.write(encoder.encode(reply));
						} catch {
							return;
						}
					}
				}
			})();
		}
	})().catch(() => {});

	return {
		address,
		close: () => listener.close(),
		authenticate,
	};
}

/** The generic driver's listen call is synchronous, so its fake daemon must run
 * in another isolate instead of waiting on this test's event loop. */
async function fakeControlWorker(): Promise<Fake> {
	const worker = new Worker(new URL("./onion_control_worker.ts", import.meta.url).href, {
		type: "module",
	});
	let authenticateResolve!: (line: string) => void;
	let authenticateReject!: (error: Error) => void;
	const authenticate = new Promise<string>((resolve, reject) => {
		authenticateResolve = resolve;
		authenticateReject = reject;
	});
	const ready = new Promise<string>((resolve, reject) => {
		worker.onmessage = (event) => {
			const message = event.data as {
				kind: string;
				address?: string;
				line?: string;
				error?: string;
			};
			if (message.kind === "ready") resolve(message.address!);
			if (message.kind === "authenticate") authenticateResolve(message.line!);
			if (message.kind === "error") {
				const error = new Error(message.error);
				authenticateReject(error);
				reject(error);
				worker.terminate();
			}
		};
		worker.onerror = (event) => {
			authenticateReject(event.error);
			reject(event.error);
			worker.terminate();
		};
	});
	worker.postMessage({ serviceId: SERVICE_ID, serviceKey: SERVICE_KEY });
	const address = await ready;
	return { address, authenticate, close: () => worker.terminate() };
}

/** A fake SOCKS endpoint: answers one handshake for `SERVICE_ID`, then reports the
 * first framed bytes the dialer wrote. */
function fakeSocks(): { address: string; close(): void; firstWrite: Promise<Uint8Array> } {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const address = `127.0.0.1:${(listener.addr as Deno.NetAddr).port}`;
	let report: (bytes: Uint8Array) => void = () => {};
	let fail: (err: Error) => void = () => {};
	const firstWrite = new Promise<Uint8Array>((resolve, reject) => {
		report = resolve;
		fail = reject;
	});

	(async () => {
		const conn = await listener.accept();
		const readExact = async (count: number): Promise<Uint8Array> => {
			const out = new Uint8Array(count);
			let got = 0;
			while (got < count) {
				const n = await conn.read(out.subarray(got));
				if (n === null) throw new Error("short read");
				got += n;
			}
			return out;
		};

		const greeting = await readExact(3);
		assertDeepEquals([...greeting], [0x05, 0x01, 0x00]);
		await conn.write(new Uint8Array([0x05, 0x00]));

		// Four header bytes, the length byte, the 62-character address, the port.
		const request = await readExact(69);
		assertDeepEquals([...request.subarray(0, 5)], [0x05, 0x01, 0x00, 0x03, 62]);
		assertDeepEquals(new TextDecoder().decode(request.subarray(5, 5 + 62)), `${SERVICE_ID}.onion`);
		// 9045, big-endian.
		assertDeepEquals([...request.subarray(67)], [0x23, 0x55]);

		await conn.write(new Uint8Array([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));

		const body = new Uint8Array(64);
		const n = await conn.read(body);
		report(body.subarray(0, n ?? 0));
		conn.close();
	})().catch((err) => fail(err instanceof Error ? err : new Error(String(err))));

	return { address, close: () => listener.close(), firstWrite };
}

Deno.test("onion: a dial carries a framed message over the circuit", async () => {
	const socks = fakeSocks();
	const net = new Netlayer({ socks: socks.address });
	try {
		const conn = await net.connect(SERVICE_ID);
		assert(conn instanceof Connection, "the package entry preserves the raw Connection class identity");
		// What reaches the wire is the frame inside its netstring envelope: a Syrup
		// byte string whose length prefix the reader strips again.
		const payload = new TextEncoder().encode(`<8'op:abort3"bye>`);
		await conn.writeFrame(payload);
		const got = await socks.firstWrite;
		assertDeepEquals(new TextDecoder().decode(got), `${payload.length}:<8'op:abort3"bye>`);
		conn.close();
	} finally {
		net.release();
		socks.close();
	}
});

Deno.test("onion: hosting reports the service Tor named", async () => {
	const control = fakeControl();
	const net = new Netlayer({ socks: "127.0.0.1:1", control: control.address });
	try {
		const listener = await net.listen();
		assertDeepEquals(listener.serviceId, SERVICE_ID);
		assertDeepEquals(listener.serviceId.length, SERVICE_ID_LENGTH);
		assertDeepEquals(new TextDecoder().decode(listener.serviceKey), SERVICE_KEY);
		// Nothing has dialed, so the wait expires rather than parking.
		assert(!(await listener.wait(1)));
		// Releasing the owner retires borrowed children before its std.Io backend.
		net.release();
		assertThrows(() => listener.readinessFd());
		listener.close(); // idempotent after owner-driven release
		assertDeepEquals(await control.authenticate, "AUTHENTICATE");
	} finally {
		net.release();
		control.close();
	}
});

Deno.test("onion: a driver lease outlives the provider constructor", async () => {
	const control = await fakeControlWorker();
	const loop = DriverLoop.open({ wireBufferBytes: 1024, maxPendingOpens: 8 });
	try {
		await installProvider(loop, { socks: "127.0.0.1:1", control: control.address });
		assert(loop.hasTransport("onion"));
		const listener = await loop.listen("onion", "");
		const locator = loop.listenerLocator(listener);
		assertDeepEquals(locator.transport, "onion");
		assertDeepEquals(locator.designator, SERVICE_ID);
		assertDeepEquals(
			new TextDecoder().decode(loop.listenerRestorationState(listener)),
			SERVICE_KEY,
		);
		await loop.closeListener(listener);
		assertThrows(() => loop.listenerRestorationState(listener));
		assertDeepEquals(await control.authenticate, "AUTHENTICATE");
	} finally {
		await loop.close();
		control.close();
	}
});

Deno.test("onion: the high-level server owns CapTP admission and projects restoration state", async () => {
	const control = await fakeControlWorker();
	try {
		const server = await listen({ socks: "127.0.0.1:1", control: control.address });
		try {
			assertDeepEquals(server.uri, `ocapn://${SERVICE_ID}.onion`);
			assertDeepEquals(server.designator, SERVICE_ID);
			assertDeepEquals(new TextDecoder().decode(server.serviceKey), SERVICE_KEY);
			const copy = server.serviceKey;
			copy.fill(0);
			assertDeepEquals(new TextDecoder().decode(server.serviceKey), SERVICE_KEY);
		} finally {
			await server.close();
		}
		assertDeepEquals(await control.authenticate, "AUTHENTICATE");
	} finally {
		control.close();
	}
});

Deno.test("onion: owner release interrupts and drains an in-flight accept", async () => {
	const control = fakeControl();
	const net = new Netlayer({ socks: "127.0.0.1:1", control: control.address });
	try {
		const listener = await net.listen();
		const accepting = listener.accept();
		// Let the serialized accept enter Deno's blocking FFI pool before close.
		await Promise.resolve();
		net.release();
		await assertRejects(() => accepting);
		assertThrows(() => listener.readinessFd());
	} finally {
		net.release();
		control.close();
	}
});

Deno.test("onion: each credential form reaches the daemon as itself", async () => {
	// A cookie file's bytes travel as hexadecimal, a password as a quoted string.
	// This is the test that catches a mapping which sends no credential at all.
	const cookie = fakeControl();
	const withCookie = new Netlayer({
		socks: "127.0.0.1:1",
		control: cookie.address,
		auth: { kind: "cookie", cookie: new Uint8Array([0x00, 0x01, 0x0f, 0xff]) },
	});
	try {
		(await withCookie.listen()).close();
		assertDeepEquals(await cookie.authenticate, "AUTHENTICATE 00010fff");
	} finally {
		withCookie.release();
		cookie.close();
	}

	const password = fakeControl();
	const withPassword = new Netlayer({
		socks: "127.0.0.1:1",
		control: password.address,
		auth: { kind: "password", password: "hunter2" },
	});
	try {
		(await withPassword.listen()).close();
		assertDeepEquals(await password.authenticate, `AUTHENTICATE "hunter2"`);
	} finally {
		withPassword.release();
		password.close();
	}
});

Deno.test("onion: a dial-only netlayer refuses to host", async () => {
	const net = new Netlayer({ socks: "127.0.0.1:1" });
	try {
		// Reporting success would leave a caller believing it was reachable at an
		// address that does not exist.
		await assertRejects(() => net.listen());
	} finally {
		net.release();
	}
});

Deno.test("onion: a malformed designator is refused before dialing", async () => {
	// The SOCKS endpoint is a port nothing listens on, so a check that ran later
	// would report a connection failure instead of an argument fault.
	const net = new Netlayer({ socks: "127.0.0.1:1" });
	try {
		const error = await assertRejects(() => net.connect("not-an-onion-address"));
		if (!(error instanceof GlowcapError)) {
			throw new Error("off-thread failure lost its typed status");
		}
		assert(
			error.detail?.includes("not a well-formed version 3 onion service id"),
			"off-thread failure lost its native diagnostic",
		);
	} finally {
		net.release();
	}
});
