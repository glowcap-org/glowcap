// How the page's wasm peer comes to exist: which module, which connectors,
// and which tracing compose the one runtime every directory session rides.
//
// Split from connection.ts so composing the runtime and holding directories
// stay two subjects: this module owns the instantiation, `connection.ts`
// owns what is opened over it. The entry module awaits `bootRuntime` while
// the opening screen is still up, and every connect path shares the same
// memoized attempt through `readyRuntime`.

import { init } from "@pancake/web";
import type { WebRuntime } from "@pancake/web";
import * as relay from "@pancake/relay";
import * as webrtc from "@pancake/webrtc";
import { iceServers } from "./ice.ts";
import { directorySignalingAuthority } from "../../../lib/signaling.ts";
import { CAPTP_VERSION, CODEC } from "../../../lib/protocol.ts";
import { readyRuntime, soleLive } from "./bootstrap.ts";
import { relayLocatorUrl, relayWsUrl } from "./reachable.ts";
import { ensureVizPublisher } from "./viz.ts";

/** Instantiate the page's wasm peer, memoized through `readyRuntime`. The
 * entry module awaits this while the opening screen is still up, because
 * locator parsing is native-backed: a component that rendered before the
 * adapter existed took the whole interface down. Every connect path below
 * shares the same attempt, so the screen's wait and the dial's wait are one
 * instantiation. A rejected attempt is not cached (`readyRuntime`), so the
 * wasm asset losing its build race is retried, not remembered. */
export function bootRuntime(): Promise<WebRuntime> {
	return readyRuntime(async () => {
		// Install tracing before `init` creates the page's long-lived Runtime
		// Host, so the visualizer sees the Host's own sessions from birth.
		await ensureVizPublisher();
		return await init({
			wasm: fetch("/pancake_host.wasm"),
			wsUrl: relayWsUrl,
			relayUrl: relayLocatorUrl,
			codec: CODEC,
			captpVersion: CAPTP_VERSION,
			connectors: [
				relay.connector(),
				webrtc.connector(directorySignalingAuthority(() => soleLive()?.dir ?? null), {
					iceServers,
				}),
			],
		});
	});
}
