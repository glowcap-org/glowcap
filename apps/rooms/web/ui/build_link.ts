// Reloads the page when its server starts serving another build.
//
// Every directory session rides the server's relay, so a restart takes every
// connection the page has. The page asks for the served build when it loses
// them all and when one comes back, and on a beat while it has none, which
// includes the wait for a first connection. Checks may overlap.

import { UI_BUILD } from "./application_data.ts";
import type { PageProjection } from "./store/projection.ts";
import { watchConnections } from "./connection_watch.ts";
import { reloadPage } from "./page_base.ts";
import { type PageStorage, sessionArea } from "./page_storage.ts";

const RECHECK_MS = 5_000;
const REQUEST_TIMEOUT_MS = 5_000;
const RELOADED_FOR_KEY = "rooms:reloaded-for-build";

/** The build this page runs, and how it reaches the server's. */
export interface PageBuild {
	readonly current: string;
	/** The build the server serves now, or null without an answer. */
	served(): Promise<string | null>;
	/** Whether navigation started. A refused reload keeps watching later builds. */
	reload(build: string): boolean;
}

/** Calls `tick` on every beat until the returned stop. */
export type Beat = (tick: () => void) => () => void;

/** Reload into the first other build the server names. Returns the stop. */
export function bindReloadToBuild(
	projection: PageProjection,
	build: PageBuild,
	beat: Beat = beatEvery(RECHECK_MS),
): () => void {
	let stopped = false;
	let stopBeat: (() => void) | null = null;
	let lost = false;
	const check = async () => {
		const served = await build.served();
		if (stopped || served == null || served === build.current) return;
		if (build.reload(served)) stop();
	};
	const stopWatching = watchConnections(projection, ({ total, seen, connected }) => {
		// Every connection the page had is gone, or one is back.
		const lostNow = seen > 0 && connected === 0;
		if (lostNow !== lost) {
			lost = lostNow;
			void check();
		}
		if (total > 0 && connected === 0) {
			stopBeat ??= beat(() => void check());
		} else {
			stopBeat?.();
			stopBeat = null;
		}
	});
	function stop() {
		stopped = true;
		stopWatching();
		stopBeat?.();
	}
	return stop;
}

function beatEvery(ms: number): Beat {
	return (tick) => {
		const id = setInterval(tick, ms);
		return () => clearInterval(id);
	};
}

/** Whether to reload for `build`. A tab does not retry its last reload target,
 * so a server whose page and `/ui-version` disagree cannot loop it on that
 * target. A different target still permits an update or rollback. A tab whose
 * browser will not keep the target never reloads by itself, because nothing
 * would stop that loop, so it stays on its build until a person reloads. */
export function firstReloadFor(build: string, storage: PageStorage): boolean {
	if (storage.read(RELOADED_FOR_KEY) === build) return false;
	return storage.write(RELOADED_FOR_KEY, build) == null;
}

const DIGEST = new RegExp(`^[0-9a-f]{${UI_BUILD.digestLength}}$`);
/** The two types a build name arrives as: `rooms-web` labels it text, and a
 * static host labels the exported extensionless `ui-version` file as bytes. */
const NAME_TYPES = ["text/plain", "application/octet-stream"];

/** The build `response` names (`rooms_application::web_build`), else null. A
 * static host that answers every path with the page is not naming a build, and
 * neither is a refused, empty, or mislabeled answer: each reads as no answer,
 * which never reloads. A mislabeled body is cancelled unread. */
export async function servedBuild(response: Response): Promise<string | null> {
	if (!response.ok || !namesBuild(response.headers.get("content-type"))) {
		await response.body?.cancel();
		return null;
	}
	return buildName(await response.text());
}

/** Whether a response labeled `contentType` can carry a build name, so a
 * mislabeled answer is dropped before its body is read. */
function namesBuild(contentType: string | null): boolean {
	return NAME_TYPES.includes(contentType?.split(";")[0].trim().toLowerCase() ?? "");
}

function buildName(body: string): string | null {
	const name = body.trim();
	const digest = name.startsWith(UI_BUILD.sourcePrefix)
		? name.slice(UI_BUILD.sourcePrefix.length)
		: name.endsWith(UI_BUILD.dirtySuffix)
		? name.slice(0, -UI_BUILD.dirtySuffix.length)
		: name;
	return DIGEST.test(digest) ? name : null;
}

/** The build stamped on `document`, or null on a page without one. */
export function servedPageBuild(document: Document): PageBuild | null {
	const current = document.documentElement.dataset.uiBuild;
	if (current == null) return null;
	return {
		current,
		async served() {
			try {
				// Beside the page, so a page under a base path asks its own host.
				const response = await fetch(new URL("ui-version", document.baseURI), {
					cache: "no-store",
					signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
				});
				return await servedBuild(response);
			} catch {
				// tolerant: an unanswered check waits for the next drop, return, or beat.
				return null;
			}
		},
		reload(build) {
			if (!firstReloadFor(build, sessionArea)) return false;
			reloadPage();
			return true;
		},
	};
}
