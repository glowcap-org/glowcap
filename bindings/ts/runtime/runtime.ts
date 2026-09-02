import { dialWithConnector } from "./dial.ts";
import { DriverLoop } from "./driver_loop.ts";
import { GlowcapError } from "./errors.ts";
import { Host } from "./host.ts";
import type { HostOptions } from "./host.ts";
import { throwIfCancelled } from "./internal/cancellation.ts";
import { ensureRuntimeReady } from "./internal/ffi/runtime.ts";
import type { CloseOptions } from "./lifecycle.ts";
import type { Locator } from "./locator.ts";
import { HANDSHAKE_TIMEOUT_MS, Session } from "./session.ts";
import type { Connector, DriverProvider, TransportOperationOptions } from "./transport.ts";
import { INVALID_ARGUMENT } from "@glowcap/abi";

type RuntimeHostOptions =
	| ({
		/** Transfer this Host's identity and live-session directory into the Runtime. */
		readonly adoptHost: Host;
		readonly seed?: never;
	} & { readonly [K in keyof HostOptions]?: never })
	| ({
		readonly adoptHost?: never;
		/** Durable 32-byte identity seed for the newly minted Host. */
		readonly seed?: Uint8Array;
	} & Readonly<HostOptions>);

type CommonRuntimeOptions = RuntimeHostOptions & {
	/** Runtime-wide OCapN handshake budget. `null` or `0` waits without a bound. */
	readonly handshakeTimeoutMs?: number | null;
};

export type RuntimeOptions =
	& CommonRuntimeOptions
	& (
		| {
			readonly providers: readonly DriverProvider[];
			readonly connectors?: never;
		}
		| {
			readonly connectors: readonly Connector[];
			readonly providers?: never;
		}
	);

export interface ConnectOptions {
	/** Cancel byte-channel establishment before the Session opens. */
	readonly signal?: AbortSignal;
	/** A typed provider override borrowed for this dial only. */
	readonly transport?: TransportOperationOptions;
}

type RuntimeMode =
	| { readonly tag: "driver"; readonly loop: DriverLoop }
	| { readonly tag: "byte-fed" };

/** One managed Host and its long-lived transport composition. */
export class Runtime {
	readonly #host: Host;
	readonly #mode: RuntimeMode;
	readonly #handshakeTimeoutMs: number | null;

	private constructor(
		host: Host,
		mode: RuntimeMode,
		handshakeTimeoutMs: number | null,
	) {
		this.#host = host;
		this.#mode = mode;
		this.#handshakeTimeoutMs = handshakeTimeoutMs;
	}

	static async open(options: RuntimeOptions): Promise<Runtime> {
		await ensureRuntimeReady();
		const handshakeTimeoutMs = options.handshakeTimeoutMs === undefined
			? HANDSHAKE_TIMEOUT_MS
			: options.handshakeTimeoutMs;
		if (options.providers != null) {
			const createdHost = options.adoptHost == null;
			const host = options.adoptHost ?? new Host(options.seed, options);
			const existingLoop = host.driverLoop;
			const loop = existingLoop == null
				? DriverLoop.takeHost(host, { handshakeMs: handshakeTimeoutMs ?? 0 })
				: existingLoop as DriverLoop;
			try {
				// Adoption is durable for caller-owned Hosts. Starting before provider
				// setup ensures a failed setup still leaves a usable loop for retry.
				loop.start();
				for (const provider of options.providers) await provider.install(loop);
				return new Runtime(host, { tag: "driver", loop }, handshakeTimeoutMs);
			} catch (error) {
				if (createdHost) await loop.close();
				throw error;
			}
		}

		const connectors = options.connectors;
		const host = options.adoptHost ?? new Host(options.seed, options);
		if (host.driverLoop != null) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"a driver-loop Host cannot be transferred to a byte-fed Runtime",
			);
		}
		try {
			host.installConnectors(connectors);
			return new Runtime(host, { tag: "byte-fed" }, handshakeTimeoutMs);
		} catch (error) {
			if (options.adoptHost == null) await host.close();
			throw error;
		}
	}

	get host(): Host {
		return this.#host;
	}

	async connect(partner: Locator, options: ConnectOptions = {}): Promise<Session> {
		this.#host.assertHandle();
		throwIfCancelled(options.signal);
		if (
			options.transport != null &&
			!options.transport.transports.includes(partner.transport)
		) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`operation options do not support transport ${JSON.stringify(partner.transport)}`,
			);
		}
		if (this.#mode.tag === "driver") {
			return await this.#mode.loop.connectSession(partner, options.transport?.data);
		}

		const connector = this.#host.connectorFor(partner.transport);
		if (connector == null) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`Runtime has no connector for transport ${JSON.stringify(partner.transport)}`,
			);
		}
		return await dialWithConnector(
			connector,
			partner,
			this.#host,
			false,
			this.#handshakeTimeoutMs,
			options.signal,
			options.transport?.data,
		);
	}

	async close(options: CloseOptions = {}): Promise<void> {
		if (this.#mode.tag === "driver") await this.#mode.loop.close(options);
		else await this.#host.close(options);
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}
}
