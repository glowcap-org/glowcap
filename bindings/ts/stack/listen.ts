// Generic native-driver listener surfaces. The driver owns the socket,
// admission, handshake, events, and terminal release; this module only
// projects listener metadata and accepted handles into the TypeScript API.

import { Session } from "./session.ts";
import { Host } from "./host.ts";
import { DriverListener, DriverLoop, loopTierAvailable } from "./driver_loop.ts";
import { installProvider as installTcpProvider } from "./transport/tcp.ts";
import { INVALID_ARGUMENT, IO } from "@pancake/abi";
import { PancakeError } from "./errors.ts";
import { type Codec } from "./value.ts";
import {
	designatorHostPort,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	keyedTcpLocator,
	noiseTcpLocator,
	parseLocator,
	socketAddrDesignator,
	stringHint,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "./locator.ts";

export interface ListenOptions {
	/** Dialable address to sign when the socket binds a wildcard interface. */
	readonly advertisedHost?: string;
}

function loopUnavailable(): PancakeError {
	return new PancakeError(
		INVALID_ARGUMENT,
		"native driver listeners require a runtime that can park the loop",
	);
}

/** A native-driver listener. Its Host is the driver's Host wrapper, which is
 * either minted by the loop or the exact supplied wrapper transferred through
 * `pancake_driver_take_host`. */
export class Server {
	readonly #listener: DriverListener | null;
	readonly #designator: string | null;
	readonly #bindError: PancakeError | null;
	readonly #ownedLoop: DriverLoop | null;
	#closePromise: Promise<void> | null = null;
	#admissionClosed = false;

	constructor(
		bound:
			| { listener: DriverListener; designator: string; ownedLoop?: DriverLoop }
			| { bindError: PancakeError },
	) {
		if ("bindError" in bound) {
			this.#listener = null;
			this.#designator = null;
			this.#bindError = bound.bindError;
			this.#ownedLoop = null;
		} else {
			this.#listener = bound.listener;
			this.#designator = bound.designator;
			this.#bindError = null;
			this.#ownedLoop = bound.ownedLoop ?? null;
		}
	}

	get port(): number {
		if (this.#designator == null) {
			throw this.#bindError ?? new PancakeError(INVALID_ARGUMENT, "server not bound");
		}
		return Number(this.#designator.slice(this.#designator.lastIndexOf(":") + 1));
	}

	ready(): Promise<number> {
		if (this.#bindError != null) return Promise.reject(this.#bindError);
		return Promise.resolve(this.port);
	}

	get host(): Host {
		if (this.#listener == null) {
			throw this.#bindError ?? new PancakeError(INVALID_ARGUMENT, "server not bound");
		}
		return this.#listener.host;
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		if (this.#listener == null) return;
		try {
			while (true) {
				const session = await this.#listener.accept();
				if (session == null) return;
				yield session;
			}
		} finally {
			await this.stopAdmission();
			// Yielded sessions may still be live after iterator close. Request
			// retirement now; the last session completes it without making iterator
			// completion wait on its own consumer.
			if (this.#ownedLoop != null) void this.#ownedLoop.requestClose();
		}
	}

	/** Close this server. A server that minted its own stack also closes that
	 * loop; a server on a caller-owned Host stops only its listener. */
	close(): void {
		void this.closeAsync();
	}

	stopAdmission(): Promise<void> {
		if (this.#admissionClosed) return Promise.resolve();
		this.#admissionClosed = true;
		try {
			this.#listener?.close();
			return Promise.resolve();
		} catch (error) {
			return Promise.reject(error);
		}
	}

	closeAsync(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		this.#closePromise = (async () => {
			await this.stopAdmission();
			if (this.#ownedLoop != null) await this.#ownedLoop.requestClose();
		})();
		return this.#closePromise;
	}

	[Symbol.dispose](): void {
		this.close();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.closeAsync();
	}
}

/** A native-loop `noise-tcp` server. Its durable key is the locator
 * designator, and every accepted channel is sealed before CapTP opens. */
export class NoiseTcpServer {
	readonly #server: Server;
	readonly #designator: string | null;
	readonly #directAddress: string | null;

	constructor(server: Server, designator: string | null, directAddress: string | null) {
		this.#server = server;
		this.#designator = designator;
		this.#directAddress = directAddress;
	}

	get port(): number {
		return this.#server.port;
	}

	ready(): Promise<number> {
		return this.#server.ready();
	}

	get host(): Host {
		return this.#server.host;
	}

	get designator(): string {
		if (this.#designator == null) {
			throw new PancakeError(INVALID_ARGUMENT, "noise-tcp server not bound");
		}
		return this.#designator;
	}

	uri(): string {
		if (this.#directAddress == null) {
			throw new PancakeError(INVALID_ARGUMENT, "noise-tcp server not bound");
		}
		const { hostname, port } = designatorHostPort(this.#directAddress);
		return noiseTcpLocator(this.designator, hostname, port);
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		for await (const session of this.#server) yield session;
	}

	close(): void {
		this.#server.close();
	}

	stopAdmission(): Promise<void> {
		return this.#server.stopAdmission();
	}

	closeAsync(): Promise<void> {
		return this.#server.closeAsync();
	}

	[Symbol.dispose](): void {
		this.close();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.closeAsync();
	}
}

function bindLoopListener(
	loop: DriverLoop,
	bindHost: string,
	port: number,
	advertisedHost: string | undefined,
): { listener: DriverListener; designator: string } {
	installTcpProvider(loop);
	const listener = DriverListener.open(
		loop,
		TRANSPORT_TCP,
		socketAddrDesignator(bindHost, port),
	);
	const boundDesignator = listener.locator().designator;
	const designator = dialableSocketAddress(boundDesignator, advertisedHost);
	if (designator !== boundDesignator) {
		listener.advertise(formatPeerUri(TRANSPORT_TCP, designator));
	}
	listener.select();
	loop.start();
	return { listener, designator };
}

function dialableSocketAddress(boundAddress: string, advertisedHost?: string): string {
	const { hostname, port } = designatorHostPort(boundAddress);
	const bare = hostname.startsWith("[") && hostname.endsWith("]")
		? hostname.slice(1, -1)
		: hostname;
	const ipv6Unspecified = bare.includes(":") &&
		bare.split(":").every((part) => part === "" || /^0+$/.test(part));
	if ((bare === "0.0.0.0" || ipv6Unspecified) && advertisedHost == null) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"a wildcard bind has no dialable address; provide advertisedHost",
		);
	}
	return advertisedHost == null ? boundAddress : socketAddrDesignator(advertisedHost, port);
}

/** Bind plain TCP through the generic driver. A supplied Host is transferred
 * before binding, preserving that wrapper as the server's Host authority. */
export function listen(
	bindHost: string,
	port: number,
	host?: Host,
	codec?: Codec,
	options: ListenOptions = {},
): Server {
	if (host != null && codec != null && codec !== host.codec) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`codec "${codec}" conflicts with the host's "${host.codec}"; mint the host with it instead`,
		);
	}
	if (!loopTierAvailable()) return new Server({ bindError: loopUnavailable() });
	let loop: DriverLoop | null = null;
	let createdLoop = false;
	try {
		if (host?.driverLoop != null) {
			loop = host.driverLoop as DriverLoop;
		} else {
			loop = host == null ? DriverLoop.open({ codec }) : DriverLoop.takeHost(host);
			createdLoop = true;
		}
		const bound = bindLoopListener(loop, bindHost, port, options.advertisedHost);
		return new Server({
			listener: bound.listener,
			designator: bound.designator,
			ownedLoop: host == null ? loop : undefined,
		});
	} catch (error) {
		if (createdLoop) void loop?.close();
		return new Server({
			bindError: error instanceof PancakeError ? error : new PancakeError(IO, String(error)),
		});
	}
}

/** Bind a native-loop `noise-tcp` server. Reuse the optional 32-byte `seed`
 * across restarts to keep the same durable key designator; a fresh per-process
 * session-key root is still drawn. */
export function listenNoiseTcp(
	bindHost: string,
	port: number,
	seed?: Uint8Array,
	codec?: Codec,
	options: Pick<ListenOptions, "advertisedHost"> = {},
): NoiseTcpServer {
	if (seed != null && seed.length !== 32) {
		throw new PancakeError(INVALID_ARGUMENT, "listenNoiseTcp: seed must be 32 bytes");
	}
	if (!loopTierAvailable()) throw loopUnavailable();
	const loop = DriverLoop.open({ seed, codec });
	try {
		installTcpProvider(loop);
		const listener = DriverListener.open(
			loop,
			TRANSPORT_NOISE_TCP,
			socketAddrDesignator(bindHost, port),
		);
		const locator = listener.locator();
		const designator = locator.designator;
		const boundDirect = stringHint(locator, HINT_DIRECT_ADDRESSES);
		if (boundDirect == null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"noise-tcp listener locator has no direct-addresses hint",
			);
		}
		const directAddress = dialableSocketAddress(boundDirect, options.advertisedHost);
		if (options.advertisedHost != null) {
			listener.advertise(formatPeerUri(
				TRANSPORT_NOISE_TCP,
				designator,
				new Map([[HINT_DIRECT_ADDRESSES, directAddress]]),
			));
		}
		listener.select();
		loop.start();
		return new NoiseTcpServer(
			new Server({ listener, designator: directAddress, ownedLoop: loop }),
			designator,
			directAddress,
		);
	} catch (error) {
		void loop.close();
		return new NoiseTcpServer(
			new Server({
				bindError: error instanceof PancakeError
					? error
					: new PancakeError(IO, String(error)),
			}),
			null,
			null,
		);
	}
}

/** A keyed-tcp listener uses the driver's keyed provider and the durable half
 * of `seed` as its locator designator. */
export class KeyedTcpServer {
	readonly #server: Server;
	readonly #designator: string | null;
	readonly #directAddress: string | null;

	constructor(server: Server, designator: string | null, directAddress: string | null) {
		this.#server = server;
		this.#designator = designator;
		this.#directAddress = directAddress;
	}

	get designator(): string {
		if (this.#designator == null) {
			throw new PancakeError(INVALID_ARGUMENT, "keyed-tcp server not bound");
		}
		return this.#designator;
	}

	get host(): Host {
		return this.#server.host;
	}

	get port(): number {
		return this.#server.port;
	}

	ready(): Promise<number> {
		return this.#server.ready();
	}

	async uri(): Promise<string> {
		if (this.#directAddress == null) {
			throw new PancakeError(INVALID_ARGUMENT, "keyed-tcp server not bound");
		}
		const { hostname, port } = designatorHostPort(this.#directAddress);
		return keyedTcpLocator(this.designator, hostname, port);
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		for await (const session of this.#server) yield session;
	}

	close(): void {
		this.#server.close();
	}

	stopAdmission(): Promise<void> {
		return this.#server.stopAdmission();
	}

	closeAsync(): Promise<void> {
		return this.#server.closeAsync();
	}

	[Symbol.dispose](): void {
		this.close();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.closeAsync();
	}
}

export function listenKeyedTcp(
	bindHost: string,
	port: number,
	seed?: Uint8Array,
	codec?: Codec,
	options: ListenOptions = {},
): KeyedTcpServer {
	if (seed != null && seed.length !== 32) {
		throw new PancakeError(INVALID_ARGUMENT, "listenKeyedTcp: seed must be 32 bytes");
	}
	if (!loopTierAvailable()) {
		return new KeyedTcpServer(new Server({ bindError: loopUnavailable() }), null, null);
	}
	const loop = DriverLoop.open({ seed, codec });
	try {
		installTcpProvider(loop);
		const listener = DriverListener.open(
			loop,
			TRANSPORT_KEYED_TCP,
			socketAddrDesignator(bindHost, port),
		);
		const locator = listener.locator();
		const designator = locator.designator;
		const boundDirect = stringHint(locator, HINT_DIRECT_ADDRESSES);
		if (boundDirect == null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"keyed-tcp listener locator has no direct-addresses hint",
			);
		}
		const directAddress = dialableSocketAddress(boundDirect, options.advertisedHost);
		if (options.advertisedHost != null) {
			listener.advertise(formatPeerUri(
				TRANSPORT_KEYED_TCP,
				designator,
				new Map([[HINT_DIRECT_ADDRESSES, directAddress]]),
			));
		}
		listener.select();
		loop.start();
		return new KeyedTcpServer(
			new Server({ listener, designator: directAddress, ownedLoop: loop }),
			designator,
			directAddress,
		);
	} catch (error) {
		void loop.close();
		return new KeyedTcpServer(
			new Server({
				bindError: error instanceof PancakeError
					? error
					: new PancakeError(IO, String(error)),
			}),
			null,
			null,
		);
	}
}
