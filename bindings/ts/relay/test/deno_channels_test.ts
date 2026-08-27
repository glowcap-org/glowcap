import { takeRuntimeFailures } from "@pancake/runtime";
import { denoTcpChannel } from "../deno_channels.ts";
import { assertEquals } from "../../dogfood/assert.ts";

type TcpConnect = (options: Deno.ConnectOptions) => Promise<Deno.TcpConn>;
const denoTcp = Deno as unknown as { connect: TcpConnect };

Deno.test("denoTcpChannel reports refusal while retiring a timed-out late connection", async () => {
	takeRuntimeFailures();
	const originalConnect = denoTcp.connect;
	let publish!: (value: Deno.TcpConn) => void;
	const connecting = new Promise<Deno.TcpConn>((resolve) => publish = resolve);
	denoTcp.connect = () => connecting;
	const closeFailure = new Error("late socket close refused");
	try {
		await denoTcpChannel("example.invalid", 1, { dialTimeoutMs: 1 }).then(
			() => {
				throw new Error("timed-out connect resolved");
			},
			(error) => assertEquals((error as Error).message, "TCP dial timeout"),
		);
		publish({
			close() {
				throw closeFailure;
			},
		} as unknown as Deno.TcpConn);
		await new Promise((resolve) => setTimeout(resolve, 0));
		const failures = takeRuntimeFailures();
		assertEquals(failures.length, 1);
		assertEquals(failures[0].operation, "relay.tcp.dial.late-close");
		assertEquals(failures[0].primaryMessage, closeFailure.message);
	} finally {
		denoTcp.connect = originalConnect;
	}
});

Deno.test("denoTcpChannel returns one close barrier after running every release", async () => {
	const originalConnect = denoTcp.connect;
	const closeFailure = new Error("socket close refused");
	let socketCloses = 0;
	let readerReleases = 0;
	let writerReleases = 0;
	const reader = {
		read: () => Promise.resolve({ done: true, value: undefined }),
		releaseLock: () => readerReleases++,
	};
	const writer = {
		write: (_chunk: Uint8Array) => Promise.resolve(),
		releaseLock: () => writerReleases++,
	};
	denoTcp.connect = () =>
		Promise.resolve({
			readable: { getReader: () => reader },
			writable: { getWriter: () => writer },
			close() {
				socketCloses++;
				throw closeFailure;
			},
		} as unknown as Deno.TcpConn);
	try {
		const channel = await denoTcpChannel("example.invalid", 1);
		const first = channel.close();
		const second = channel.close();
		assertEquals(first, second);
		await first.catch((error) => assertEquals(error, closeFailure));
		assertEquals(socketCloses, 1);
		assertEquals(readerReleases, 1);
		assertEquals(writerReleases, 1);
	} finally {
		denoTcp.connect = originalConnect;
	}
});

Deno.test("denoTcpChannel treats an auto-retired socket as closed", async () => {
	const originalConnect = denoTcp.connect;
	let readerReleases = 0;
	let writerReleases = 0;
	denoTcp.connect = () =>
		Promise.resolve({
			readable: {
				getReader: () => ({
					read: () => Promise.resolve({ done: true, value: undefined }),
					releaseLock: () => readerReleases++,
				}),
			},
			writable: {
				getWriter: () => ({
					write: (_chunk: Uint8Array) => Promise.resolve(),
					releaseLock: () => writerReleases++,
				}),
			},
			close() {
				throw new Deno.errors.BadResource("socket is already closed");
			},
		} as unknown as Deno.TcpConn);
	try {
		const channel = await denoTcpChannel("example.invalid", 1);
		await channel.close();
		assertEquals(readerReleases, 1);
		assertEquals(writerReleases, 1);
	} finally {
		denoTcp.connect = originalConnect;
	}
});
