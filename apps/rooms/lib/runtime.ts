import * as iroh from "@glowcap/iroh";
import { Runtime, TRANSPORT_IROH, TRANSPORT_KEYED_TCP, TRANSPORT_TCP } from "@glowcap/runtime";
import type { Host } from "@glowcap/runtime";
import * as tcp from "@glowcap/tcp";
import * as relay from "@glowcap/relay";
import { roomsHost, roomsLocator } from "./locator.ts";

type Cleartext = typeof tcp.plain | typeof tcp.keyed;

/** The cleartext TCP profile a supplied locator names, for
 * `RoomsRuntimeOptions.cleartext`. A sealed or non-TCP locator names none. */
export function cleartextOf(locator: string): readonly Cleartext[] {
	switch (roomsLocator(locator).transport) {
		case TRANSPORT_TCP:
			return [tcp.plain];
		case TRANSPORT_KEYED_TCP:
			return [tcp.keyed];
		default:
			return [];
	}
}

interface RoomsRuntimeOptions {
	readonly host?: Host;
	/** The iroh provider a listener already installed on the adopted Host. */
	readonly installedTransport?: typeof TRANSPORT_IROH;
	/** The cleartext TCP profiles the operator named. `noise-tcp` is always
	 * registered, so a handoff alone never opens a cleartext dial. */
	readonly cleartext?: readonly Cleartext[];
	/** Include iroh when this peer dials it. */
	readonly iroh?: iroh.IrohConfig;
	/** Include the encrypted rendezvous carrier when this peer reaches browser members. */
	readonly relay?: relay.RelayOptions;
}

/** Open one Rooms Runtime with explicit transport composition. */
export async function openRoomsRuntime(options: RoomsRuntimeOptions = {}): Promise<Runtime> {
	return await Runtime.open({
		adoptHost: options.host ?? roomsHost(),
		providers: [
			tcp.provider({ profiles: [tcp.noise, ...(options.cleartext ?? [])] }),
			...(options.relay == null ? [] : [relay.provider(options.relay)]),
			...(options.iroh == null || options.installedTransport === TRANSPORT_IROH
				? []
				: [iroh.provider(options.iroh)]),
		],
	});
}
