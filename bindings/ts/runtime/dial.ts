// Transport-neutral connection and handoff dialing. Native I/O enters through
// an explicitly selected DriverProvider; an embedder that owns channel
// establishment supplies a Connector. Transport packages construct both and
// own locator interpretation.

import { checkHost, PancakeError } from "./errors.ts";
import { Host } from "./host.ts";
import { hostS } from "./internal/ffi/host.ts";
import { L } from "./internal/layout.ts";
import { ab } from "./internal/seam.ts";
import { type Locator, OwnedLocator } from "./locator.ts";
import { HANDSHAKE_TIMEOUT_MS, Session } from "./session.ts";
import type { Connector } from "./transport.ts";
import { BUFFER_TOO_SMALL, INVALID_ARGUMENT } from "@pancake/abi";

const utf8Encoder = new TextEncoder();

export async function dialWithConnector(
	connector: Connector,
	locator: Locator,
	host: Host,
	redeem: boolean,
	handshakeTimeoutMs: number | null,
	signal?: AbortSignal,
	transportOptions?: Uint8Array,
): Promise<Session> {
	if (!connector.supports(locator.transport)) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`connector does not advertise transport ${JSON.stringify(locator.transport)}`,
		);
	}
	if (host.driverLoop != null) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"a native-loop Host cannot open an embedder-owned byte channel",
		);
	}
	return await connector.connect(host, locator, {
		redeem,
		handshakeTimeoutMs,
		signal,
		transportOptions,
	});
}

export async function dialExporter(
	locator: Locator,
	host: Host,
	signal?: AbortSignal,
): Promise<Session> {
	if (host.driverLoop != null) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"native-loop handoff dials are owned by the driver",
		);
	}
	const connector = host.connectorFor(locator.transport);
	if (connector == null) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`byte-fed Host has no connector for transport ${JSON.stringify(locator.transport)}`,
		);
	}
	return await dialWithConnector(
		connector,
		locator,
		host,
		true,
		HANDSHAKE_TIMEOUT_MS,
		signal,
	);
}

/** Execute one byte-fed Host DIAL action and report its terminal result. */
export async function runDialTicket(
	host: Host,
	ticket: bigint,
	signal?: AbortSignal,
): Promise<void> {
	let session: Session | null = null;
	try {
		if (host.released || signal?.aborted) return;
		let capacity = 4;
		let locator: Locator;
		for (;;) {
			const hints = new Uint8Array(L.LOCATOR_HINT_VIEW_SIZE * capacity);
			const view = new Uint8Array(L.LOCATOR_VIEW_SIZE);
			const count = new Uint8Array(L.ptrSize);
			const rc = hostS.pancake_host_pending_dial(
				host.raw,
				ticket,
				ab(hints),
				BigInt(capacity),
				ab(view),
				ab(count),
			);
			if (rc === BUFFER_TOO_SMALL) {
				capacity = Number(L.getUsize(new DataView(count.buffer), 0));
				continue;
			}
			checkHost(rc);
			const owned = OwnedLocator.cloneView(view);
			try {
				locator = owned.value();
			} finally {
				owned.release();
			}
			break;
		}
		session = await dialExporter(locator!, host, signal);
		if (host.released || signal?.aborted) {
			session.closeTransport();
			return;
		}
		checkHost(hostS.pancake_host_dialed(host.raw, ticket, session.raw));
		// A reported dial retires close-relevant pending work; wake any parked
		// close driver.
		host.signalCloseActivity();
		const reported = session;
		void reported.serve().catch(async (error) => {
			host.recordBackgroundFailure(error);
			try {
				await reported.closeTransport();
			} catch (cleanup) {
				host.recordBackgroundFailure(cleanup);
			}
		});
		session = null;
	} catch (error) {
		session?.closeTransport();
		if (host.released || signal?.aborted) return;
		const reason = utf8Encoder.encode(error instanceof Error ? error.message : String(error));
		checkHost(hostS.pancake_host_dial_failed(
			host.raw,
			ticket,
			ab(reason),
			BigInt(reason.length),
		));
		host.signalCloseActivity();
	}
}
