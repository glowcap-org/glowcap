import * as iroh from "@pancake/iroh";
import { Runtime, TRANSPORT_IROH, TRANSPORT_TCP } from "@pancake/runtime";
import type { Host } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import * as relay from "@pancake/relay";
import { roomsHost } from "./locator.ts";

export interface RoomsRuntimeOptions {
	readonly host?: Host;
	/** The provider already installed by a listener on the adopted Host. */
	readonly installedTransport?: typeof TRANSPORT_TCP | typeof TRANSPORT_IROH;
	/** Include iroh only when this peer actually dials it. */
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
