import * as iroh from "@pancake/iroh";
import { Runtime } from "@pancake/runtime";
import type { Host } from "@pancake/runtime";
import * as tcp from "@pancake/tcp";
import * as relay from "@pancake/relay";
import { roomsHost } from "./locator.ts";

export interface RoomsRuntimeOptions {
	readonly host?: Host;
	/** Include iroh only when this peer actually dials it. */
	readonly iroh?: iroh.IrohConfig;
	/** Include the encrypted rendezvous carrier when this peer reaches browser members. */
	readonly relay?: relay.RelayOptions;
}

/** Open one native Rooms Runtime with explicit transport composition. */
export async function openRoomsRuntime(options: RoomsRuntimeOptions = {}): Promise<Runtime> {
	return await Runtime.open({
		adoptHost: options.host ?? roomsHost(),
		providers: [
			tcp.provider(),
			...(options.relay == null ? [] : [relay.provider(options.relay)]),
			...(options.iroh == null ? [] : [iroh.provider(options.iroh)]),
		],
	});
}
