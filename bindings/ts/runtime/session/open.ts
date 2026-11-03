// Open the native session; the public Session owns handshake and retirement.
import { checkHost } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import type { Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer } from "../internal/seam.ts";
import { type Locator, withOwnedLocator } from "../locator.ts";
import type { AcceptedTransport } from "./channel.ts";

const utf8Encoder = new TextEncoder();

export function openDialed(host: Ptr, locator: Locator): Ptr {
	const out = new Uint8Array(8);
	withOwnedLocator(
		locator,
		(owned) => checkHost(hostS.glowcap_host_session_open_dialed_locator(host, owned.borrowView(), ab(out))),
	);
	return outPointer(out);
}

export function openAccepted(host: Ptr, accepted: AcceptedTransport): Ptr {
	const {
		transport: transportName,
		designatorScheme,
		serverDesignator,
		localAddress: acceptedLocalAddr = "",
	} = accepted;
	const server = utf8Encoder.encode(serverDesignator);
	const local = utf8Encoder.encode(acceptedLocalAddr);
	const t = utf8Encoder.encode(transportName);
	const out = new Uint8Array(8);
	const openCode = hostS.glowcap_host_session_open_accepted(
		host,
		ab(t),
		BigInt(t.length),
		designatorScheme,
		ab(server),
		BigInt(server.length),
		ab(local),
		BigInt(local.length),
		ab(out),
	);
	checkHost(openCode);
	return outPointer(out);
}
