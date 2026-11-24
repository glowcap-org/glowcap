// A page holding management access over links the test breaks: a saved access
// it restores when it opens, and whatever the test attaches or shares from it.
// The page dials `held_access_fakes.ts`'s controls, which answer from the plan
// in `held_access_plan.ts`. This file builds the viewer over them and gives the
// test its verbs.
import type { RoomsManagedControl } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { HeldControl } from "../../web/ui/session/managed/held_control.ts";
import { backoff } from "../../web/ui/session/managed/link.ts";
import { assert } from "../assert.ts";
import { settle, until } from "./wait.ts";
import { deferred, viewer } from "./managed_viewer.ts";
import { closed, everyReached, FakeClock, fakeHandle, linkedWorkspace } from "./managed_link.ts";
import { Fakes } from "./held_access_fakes.ts";
import { gone, Ledger, type Park, plan as newPlan } from "./held_access_plan.ts";

/** Wait for `ready`, which fakes answer within a few turns, before `until`'s
 * slower polling takes over. The tables wait for thousands of links. */
async function soon(ready: () => boolean, what: string): Promise<void> {
	for (let turn = 0; turn < 100; turn++) {
		if (ready()) return;
		await settle();
	}
	await until(ready, what);
}

/** A page holding the saved access `source`, reached. `delegates` says whether
 * the source may make a narrower control for someone else. */
export async function page({ delegates = false }: { delegates?: boolean } = {}) {
	const ledger = new Ledger();
	const reports: unknown[] = [];
	const plan = newPlan();
	plan.delegates = delegates;
	const fakes = new Fakes(ledger, plan);
	/** Each link the page dialed, the current one last. */
	const links: ReturnType<typeof linkedWorkspace>[] = [];
	const link = () => {
		const next = linkedWorkspace(`link ${links.length + 1}`, []);
		Object.assign(next.workspace, fakes.workspace());
		links.push(next);
		return next.workspace;
	};
	const clock = new FakeClock();
	const session = viewer(
		link(),
		(_source, error) => reports.push(error),
		{
			relink: () => Promise.resolve(link()),
			attachControl: () => fakes.holder("attached"),
			savedControl: (id: string) => fakes.dial(id),
		},
		false,
		clock,
	);
	await session.start();
	let closing = false;
	const management = session.management;
	await management.restore(["source"], everyReached);
	return {
		session,
		management,
		ledger,
		plan,
		reports,
		links: () => links.length,
		source: (options: { revoked?: boolean } = {}) => fakes.source(options),
		/** Close the page, as its tab closing does. */
		close: () => {
			closing = true;
			return session.close();
		},
		/** Wait out every move of held access under way. A closed page moves
		 * nothing. */
		moved: () => closing ? Promise.resolve() : management.restore([], everyReached),
		/** Break the page's current link, and wait for the next. A link lost soon
		 * after it came back waits out a backoff before the page dials again. */
		breakLink: async () => {
			const dialed = links.length;
			fakes.breakLine();
			links[dialed - 1]?.lose();
			if (dialed > 1) {
				await soon(() => closing || session.link?.state.kind === "waiting", "the link to wait before it dials");
				const state = session.link?.state;
				if (state?.kind === "waiting") clock.advance(backoff(state.attempt, clock.chance));
			}
			await soon(() => closing || (links.length > dialed && session.link?.live === true), "the next link");
		},
		dropSource: () => fakes.dropSource(),
		sourceRow: (): HeldControl => {
			const held = management.held.find((control) => control.id === "source");
			assert(held != null, "the source is held");
			return held;
		},
		/** Hold the `at`th call from now open, and say when it is reached. */
		park: (at: number): Park => {
			const held: Park = { at, count: 0, hit: deferred<void>(), release: deferred<void>() };
			plan.park = held;
			return held;
		},
		/** The page's own control, as a page that runs its session holds it. */
		ownControl: () => fakes.holder("own").then((handle) => fakeHandle<RoomsManagedControl>(handle)),
	};
}
export type Page = Awaited<ReturnType<typeof page>>;

export const restored = (f: Page) => () => Promise.resolve(f.source());
export const unreached = () => Promise.reject(closed());
export const lostForGood = () => Promise.reject(gone());
/** A restore that answers a source its session has revoked. */
export const revoked = (f: Page) => () => Promise.resolve(f.source({ revoked: true }));
