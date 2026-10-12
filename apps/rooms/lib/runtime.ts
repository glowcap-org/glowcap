import * as iroh from "@glowcap/iroh";
import { Runtime, TRANSPORT_IROH, TRANSPORT_TCP } from "@glowcap/runtime";
import type { Host } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import * as relay from "@glowcap/relay";
import { roomsHost } from "./locator.ts";

export interface RoomsRuntimeOptions {
	readonly host?: Host;
	/** The provider already installed by a listener on the adopted Host. */
	readonly installedTransport?: typeof TRANSPORT_TCP | typeof TRANSPORT_IROH;
	/** Include iroh when this peer dials it. */
	readonly iroh?: iroh.IrohConfig;
	/** Include the encrypted rendezvous carrier when this peer reaches browser members. */
	readonly relay?: relay.RelayOptions;
}

/** Open one native Rooms Runtime with explicit transport composition. */
export async function openRoomsRuntime(options: RoomsRuntimeOptions = {}): Promise<Runtime> {
	const installed = options.installedTransport;
	return await Runtime.open({
		adoptHost: options.host ?? roomsHost(),
		providers: [
			...(installed === TRANSPORT_TCP ? [] : [tcp.provider()]),
			...(options.relay == null ? [] : [relay.provider(options.relay)]),
			...(options.iroh == null || installed === TRANSPORT_IROH ? [] : [iroh.provider(options.iroh)]),
		],
	});
}
