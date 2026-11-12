// The encrypted transport the demo programs use: Noise_XK over TCP.
//
// A server listens with a fresh identity and prints its locator, an `ocapn://`
// URI that names the server's key and its address. A client dials that URI,
// and finishing the handshake proves it reached the key the URI names. Nobody
// else on the network can read or alter the session.
//
// A client opens its runtime with `tcp.provider()`,
// so the runtime refuses to dial any other transport.

import * as tcp from "@glowcap/tcp";

/** Listen on loopback `port` (0 for any free port). The server's `uri` is the
 * locator a client dials. */
export async function listenSealed(port: number): Promise<tcp.Server> {
	return await tcp.noise.listen("127.0.0.1", port);
}
