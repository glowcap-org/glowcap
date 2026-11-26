// Each standing a share can hold, how a page reaches it, and what the page
// offers there, over the fakes of `held_access_page.ts`. The share tables walk every
// standing against every event.
import { assert } from "../assert.ts";
import { shareStep } from "../../web/ui/session/managed/share_state.ts";
import { settle } from "./wait.ts";
import type { ShareGesture } from "./share_offers.ts";
import { loseSource, made, prepareShare } from "./share_gestures.ts";
import { refused, relink } from "./held_access_gestures.ts";
import { lostForGood, type Page, page } from "./held_access_page.ts";

async function saved(f: Page): Promise<void> {
	await f.management.submitIssue();
	await f.management.save(made(f));
}
/** Where `f`'s share stands, in the tables' words: its phase and step, or
 * `none` once no share is under way. */
export function standing(f: Page): string {
	const issue = f.management.issue;
	return issue == null ? "none" : `${issue.phase} ${shareStep(issue).kind}`;
}
/** A page whose share stands at `start`, one of `starts`. */
export async function reach(start: string, options: { delegates?: boolean } = {}): Promise<Page> {
	const f = await page(options);
	await prepareShare(f);
	await stand(f, start);
	await settle();
	return f;
}
/** Bring `f`'s share to `start`, one of `starts`. */
export async function stand(f: Page, start: string): Promise<void> {
	const to = starts[start];
	assert(to != null, `a share can stand ${start}`);
	await to(f);
}
/** Each standing a share can hold, and how a page reaches it. */
export const starts: Record<string, (f: Page) => Promise<void>> = {
	prepared: async (_f: Page) => {},
	uncertain: async (f: Page) => {
		f.plan.answer = "uncertain";
		await f.management.submitIssue();
	},
	conflict: async (f: Page) => {
		f.plan.answer = "conflict";
		await f.management.submitIssue();
	},
	made: async (f: Page) => {
		await f.management.submitIssue();
	},
	unreached: async (f: Page) => {
		f.plan.read = "transient";
		await refused(() => f.management.submitIssue());
	},
	saved: (f: Page) => saved(f),
	linked: async (f: Page) => {
		await saved(f);
		await f.management.publishIssue();
	},
	removed: async (f: Page) => {
		await saved(f);
		await f.management.forget(made(f));
	},
	lost: async (f: Page) => {
		await f.management.submitIssue();
		f.plan.sources.push(lostForGood);
		await relink(f);
	},
	"prepared, source lost": async (f: Page) => {
		await loseSource(f);
	},
	"uncertain, source lost": async (f: Page) => {
		f.plan.answer = "uncertain";
		await f.management.submitIssue();
		await loseSource(f);
	},
	"unreached, source lost": async (f: Page) => {
		f.plan.read = "transient";
		await refused(() => f.management.submitIssue());
		await loseSource(f);
	},
};
/** What the page offers at each standing, in the order `shareGestures` names them. */
export const offeredAt: Record<string, readonly ShareGesture[]> = {
	prepared: ["press", "finish"],
	uncertain: ["press"],
	conflict: ["finish", "remove the source"],
	made: ["press", "save"],
	unreached: ["press", "Try now on the new access"],
	saved: ["press", "remove the new access"],
	linked: ["finish", "remove the new access", "remove the source"],
	removed: ["press"],
	lost: ["finish", "remove the source"],
	"prepared, source lost": ["finish", "Try now on the source"],
	"uncertain, source lost": ["Try now on the source"],
	"unreached, source lost": ["Try now on the source", "Try now on the new access"],
};
