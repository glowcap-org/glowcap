// How the page's wasm peer comes to exist: which module, which connectors,
// and which tracing compose the one runtime every directory session rides.
//
// Split from connection.ts so composing the runtime and holding directories
// stay two subjects: this module owns the instantiation, `connection.ts`
// owns what is opened over it. The entry module awaits `bootRuntime` while
// the opening screen is still up, and every connect path shares the same
// memoized attempt through `readyRuntime`.

import { init } from "@glowcap/web";
import type { WebRuntime } from "@glowcap/web";
import * as relay from "@glowcap/relay";
import * as webrtc from "@glowcap/webrtc";
import { iceServers } from "./ice.ts";
import { directorySignalingAuthority } from "../../../lib/signaling.ts";
import { roomsHostOptions } from "../../../lib/profile.ts";
import { readyRuntime } from "./bootstrap.ts";
import { relayLocatorUrl, relayWsUrl } from "./reachable.ts";
import { webrtcSignalingRoute } from "./webrtc_route.ts";
import type { RoomsPageContext } from "../page.ts";

/** Instantiate the page's wasm peer, memoized through `readyRuntime`. The
 * entry module awaits this while the opening screen is still up, because
 * locator parsing is native-backed: a component that rendered before the
 * adapter existed took the whole interface down. Every connect path below
 * shares the same attempt, so the screen's wait and the dial's wait are one
 * instantiation. A rejected attempt is not cached (`readyRuntime`), so the
 * wasm asset losing its build race is retried, not remembered. */
export function bootRuntime(page: RoomsPageContext): Promise<WebRuntime> {
	return readyRuntime(page, async () => {
		return await init({
			wasm: fetch("/glowcap_host.wasm"),
			...roomsHostOptions(),
			wsUrl: relayWsUrl,
			relayUrl: relayLocatorUrl,
			connectors: [
				relay.connector(),
				webrtc.connector(
					directorySignalingAuthority(() => webrtcSignalingRoute(page)),
					{
						iceServers,
					},
				),
			],
		});
	});
}
