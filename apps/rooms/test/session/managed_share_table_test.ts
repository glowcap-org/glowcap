// Every standing of a share meets every event a page can bring it, and lands
// where the table says: its standing, the step its card offers, and the
// refusal a gesture meets. A gesture the page does not offer at a standing is
// not pressed, and its cell says so. Every handle the session hands the page
// is freed exactly once by the time the page closes, and none is used after
// its free.
import { assert, assertEquals } from "../assert.ts";
import { described } from "../../web/ui/session/managed/held_control.ts";
import { settle } from "../support/wait.ts";
import { noCeilings } from "../support/managed_link.ts";
import { deferred } from "../support/managed_viewer.ts";
import { LocalRefusal, refusalText } from "../../lib/text/failure.ts";
import type { LocalRefusalKey } from "../../lib/text/local_refusals.ts";
import { waitsOnSource } from "../../web/ui/session/managed/share_state.ts";
import { rowOffers, rowShows } from "../../web/ui/session/managed/access_row.ts";
import { cardOffers } from "../../web/ui/session/managed/access_card.ts";
import type { ShareGesture } from "../support/share_offers.ts";
import { gestures, loseSource, made, offers, prepareShare } from "../support/share_gestures.ts";
import { closedClean, refused, relink } from "../support/held_access_gestures.ts";
import { LandingTable } from "../support/landing_table.ts";
import { noTransport } from "../support/held_access_plan.ts";
import { lostForGood, type Page, page, restored, unreached } from "../support/held_access_page.ts";
import { offeredAt, reach, stand, standing as shareStanding, starts } from "../support/share_standings.ts";

/** What an event met: each refusal's code, or `unoffered` for a gesture the
 * page did not offer. */
type Met = (string | null)[];
/** Press `gesture` if the page offers it now. */
const press = (gesture: ShareGesture) => async (f: Page): Promise<Met> =>
	offers(f).includes(gesture) ? [await refused(() => gestures[gesture](f))] : ["unoffered"];
const relinked = (f: Page): Promise<Met> => relink(f).then(() => []);
/** Make the source lose its own connection, then reach it with Try now. */
async function tryNowOnSource(f: Page, reach: () => Promise<unknown>): Promise<Met> {
	await loseSource(f);
	f.plan.sources.push(reach);
	return [await refused(() => gestures["Try now on the source"](f))];
}
/** Make a narrower control from the source, which may delegate, if its card
 * offers it. When the source's connection `drops` before the new control's link
 * is read, the loss is the source's, so its row offers Try now. */
const narrowerFromSource = (drops: boolean) => async (f: Page): Promise<Met> => {
	const source = f.sourceRow();
	if (!described(source) || !cardOffers(f.management, source, undefined).share) return ["unoffered"];
	f.plan.narrowerLost = drops;
	const met = await refused(() => f.management.share(source, narrower));
	await settle();
	await f.moved();
	assertEquals(rowOffers(f.management, source).tryNow, drops, "the source's row offers Try now after its own loss");
	return [met];
};
const narrower = {
	inspect: true,
	pause: false,
	resume: false,
	revoke: false,
	delegateControl: false,
	editCeiling: null,
	issueCeiling: null,
};

/** Each event a page can bring a share. A `new access read` event is marked
 * `read` when the share read a new access. */
const events: Record<string, (f: Page) => Promise<Met>> = {
	"relink, source restored": relinked,
	"relink, source unreached": (f) => {
		f.plan.sources.push(unreached);
		return relinked(f);
	},
	"relink, source gone": (f) => {
		f.plan.sources.push(lostForGood);
		return relinked(f);
	},
	"relink, source transport unavailable": (f) => {
		f.plan.sources.push(() => Promise.reject(noTransport()));
		return relinked(f);
	},
	"relink, new access read times out": (f) => {
		f.plan.read = "transient";
		return relinked(f);
	},
	"relink, new access read fails for good": (f) => {
		f.plan.read = "final";
		return relinked(f);
	},
	"press": press("press"),
	"press, new access read times out": (f) => {
		f.plan.read = "transient";
		return press("press")(f);
	},
	"press, new access read fails for good": (f) => {
		f.plan.read = "final";
		return press("press")(f);
	},
	"Try now on the source": (f) => tryNowOnSource(f, restored(f)),
	"Try now on the source fails for good": (f) => tryNowOnSource(f, lostForGood),
	"Try now on the source, whose read times out, then press": async (f) => {
		const tried = await tryNowOnSource(f, () => {
			f.plan.sourceRead = "transient";
			return restored(f)();
		});
		return offers(f).includes("press") ? [...tried, ...await press("press")(f)] : tried;
	},
	"Try now on the new access": press("Try now on the new access"),
	"remove the new access": press("remove the new access"),
	"remove the source": press("remove the source"),
	"save": press("save"),
	"save during a move": async (f) => {
		const restoring = deferred<void>();
		f.plan.sources.push(() => restoring.promise.then(() => f.source()));
		await f.breakLink();
		const saving = press("save")(f);
		await settle();
		restoring.resolve();
		const met = await saving;
		await f.moved();
		return met;
	},
	"the source's connection drops, then press": (f) => {
		f.dropSource();
		return press("press")(f);
	},
	"the source's connection drops, then save": (f) => {
		f.dropSource();
		return press("save")(f);
	},
	"finish": press("finish"),
	"make a narrower control from the source": narrowerFromSource(false),
	"make a narrower control from the source, whose connection drops before its link is read": narrowerFromSource(true),
	"close": async (f) => {
		await f.close();
		return [];
	},
};

/** Where each standing lands after each event: `<phase> <step>`, `none` once
 * no share is under way, `!<code>` for each refusal a gesture met,
 * `unoffered` for a gesture the page did not offer, `waits` when the share
 * waits on its source, and `read` when it read a new access. A tuple adds the
 * reason the card gives. A null cell is an event that cannot reach a new
 * access's read at that standing. A row lists its usual cell and the others. */
type Cell = string | readonly [string, LocalRefusalKey] | null;
const unread = null;
function row(usual: Cell, cells: Record<string, Cell>): Record<string, Cell> {
	return Object.fromEntries(Object.keys(events).map((event) => [event, event in cells ? cells[event] : usual]));
}
/** A share the source's Try now reaches again goes on, though the read after
 * the reach times out, which the press says. */
const sourceReadTimesOut = {
	"Try now on the source, whose read times out, then press": "committed done !session-request-timed-out",
} satisfies Record<string, Cell>;
const noRead = {
	"relink, new access read times out": unread,
	"relink, new access read fails for good": unread,
	"press, new access read times out": unread,
	"press, new access read fails for good": unread,
};
const unconfirmed = (phase: string, key: LocalRefusalKey) =>
	row(`${phase} unoffered`, {
		"relink, source restored": `${phase}`,
		"relink, source unreached": `${phase} waits`,
		"relink, source gone": ["lost done", key],
		"relink, source transport unavailable": ["lost done", key],
		"relink, new access read times out": unread,
		"relink, new access read fails for good": unread,
		"press": "committed done",
		"press, new access read times out": "committed ask read",
		"press, new access read fails for good": ["lost done read", "access-share-unread"],
		"Try now on the source": `${phase}`,
		"Try now on the source fails for good": ["lost done", key],
		...sourceReadTimesOut,
		"the source's connection drops, then press": "uncertain recover waits",
		"make a narrower control from the source": `${phase}`,
		"make a narrower control from the source, whose connection drops before its link is read":
			`${phase} !session-unreachable waits`,
		"close": "none",
	});
const table: Record<string, Record<string, Cell>> = {
	// Closing the card lets go of a share that sent nothing.
	prepared: { ...unconfirmed("prepared send", "access-share-unsent"), "finish": "none" },
	uncertain: unconfirmed("uncertain recover", "access-share-lost-unknown"),
	conflict: row("conflict review unoffered", {
		...noRead,
		"relink, source restored": "conflict review",
		"relink, source unreached": "conflict review",
		"relink, source gone": "conflict review",
		"relink, source transport unavailable": "conflict review",
		"Try now on the source": "conflict review",
		"Try now on the source fails for good": "conflict review",
		"Try now on the source, whose read times out, then press": "conflict review !session-request-timed-out",
		"remove the source": "none",
		"finish": "none",
		"make a narrower control from the source": "conflict review",
		"make a narrower control from the source, whose connection drops before its link is read":
			"conflict review !session-unreachable",
		"close": "none",
	}),
	made: row("committed save unoffered", {
		"relink, source restored": "committed save",
		"relink, source unreached": "committed ask waits",
		"relink, source gone": ["lost done", "access-share-lost"],
		"relink, source transport unavailable": ["lost done", "access-share-lost"],
		"relink, new access read times out": "committed ask read",
		"relink, new access read fails for good": ["lost done read", "access-share-unread"],
		"press": "committed done",
		"press, new access read times out": unread,
		"press, new access read fails for good": unread,
		"Try now on the source": "committed save",
		"Try now on the source fails for good": ["lost done", "access-share-lost"],
		...sourceReadTimesOut,
		"save": "committed publish",
		"save during a move": "committed publish",
		"the source's connection drops, then press": "committed ask !session-unreachable waits",
		"the source's connection drops, then save": "committed ask !session-unreachable waits",
		"make a narrower control from the source": "committed save",
		"make a narrower control from the source, whose connection drops before its link is read":
			"committed ask !session-unreachable waits",
		"close": "none",
	}),
	unreached: row("committed ask unoffered", {
		"relink, source restored": "committed save",
		"relink, source unreached": "committed ask waits",
		"relink, source gone": ["lost done", "access-share-lost"],
		"relink, source transport unavailable": ["lost done", "access-share-lost"],
		"relink, new access read times out": "committed ask read",
		"relink, new access read fails for good": ["lost done read", "access-share-unread"],
		"press": "committed done",
		"press, new access read times out": "committed ask read",
		"press, new access read fails for good": ["lost done read", "access-share-unread"],
		"Try now on the source": "committed save",
		"Try now on the source fails for good": ["lost done", "access-share-lost"],
		...sourceReadTimesOut,
		"Try now on the new access": "committed save",
		"save during a move": "committed save unoffered",
		"the source's connection drops, then press": "committed ask waits",
		"make a narrower control from the source": "committed ask",
		"make a narrower control from the source, whose connection drops before its link is read":
			"committed ask !session-unreachable waits",
		"close": "none",
	}),
	saved: row("committed publish unoffered", {
		...noRead,
		"relink, source restored": "committed publish",
		"relink, source unreached": "committed ask waits",
		"relink, source gone": ["lost done", "access-share-unlinked"],
		"relink, source transport unavailable": ["lost done", "access-share-unlinked"],
		"press": "committed done",
		"Try now on the source": "committed publish",
		"Try now on the source fails for good": ["lost done", "access-share-unlinked"],
		...sourceReadTimesOut,
		"remove the new access": "committed publish",
		"the source's connection drops, then press": "committed ask !session-unreachable waits",
		"make a narrower control from the source": "committed publish",
		"make a narrower control from the source, whose connection drops before its link is read":
			"committed ask !session-unreachable waits",
		"close": "none",
	}),
	linked: row("committed done", {
		...noRead,
		"press": "committed done unoffered",
		...sourceReadTimesOut,
		"Try now on the new access": "committed done unoffered",
		"remove the source": "none",
		"save": "committed done unoffered",
		"save during a move": "committed done unoffered",
		"the source's connection drops, then press": "committed done unoffered",
		"the source's connection drops, then save": "committed done unoffered",
		"finish": "none",
		"make a narrower control from the source, whose connection drops before its link is read":
			"committed done !session-unreachable",
		"close": "none",
	}),
	removed: row("committed publish unoffered", {
		...noRead,
		"relink, source restored": "committed publish",
		"relink, source unreached": "committed ask waits",
		"relink, source gone": ["lost done", "access-share-lost-removed"],
		"relink, source transport unavailable": ["lost done", "access-share-lost-removed"],
		"press": "committed done",
		"Try now on the source": "committed publish",
		"Try now on the source fails for good": ["lost done", "access-share-lost-removed"],
		...sourceReadTimesOut,
		"the source's connection drops, then press": "committed ask !session-unreachable waits",
		"make a narrower control from the source": "committed publish",
		"make a narrower control from the source, whose connection drops before its link is read":
			"committed ask !session-unreachable waits",
		"close": "none",
	}),
	lost: row(["lost done", "access-share-lost"], {
		...noRead,
		"press": ["lost done unoffered", "access-share-lost"],
		"Try now on the source, whose read times out, then press": [
			"lost done !session-request-timed-out",
			"access-share-lost",
		],
		"Try now on the new access": ["lost done unoffered", "access-share-lost"],
		"remove the new access": ["lost done unoffered", "access-share-lost"],
		"remove the source": "none",
		"save": ["lost done unoffered", "access-share-lost"],
		"save during a move": ["lost done unoffered", "access-share-lost"],
		"the source's connection drops, then press": ["lost done unoffered", "access-share-lost"],
		"the source's connection drops, then save": ["lost done unoffered", "access-share-lost"],
		"finish": "none",
		"make a narrower control from the source": ["lost done unoffered", "access-share-lost"],
		"make a narrower control from the source, whose connection drops before its link is read": [
			"lost done unoffered",
			"access-share-lost",
		],
		"close": "none",
	}),
};

/** Where `f`'s share stands, in the table's words, after an event met `met`. */
function standing(f: Page, met: Met, read: boolean): string {
	const issue = f.management.issue;
	const said = [shareStanding(f)];
	for (const code of met) if (code != null) said.push(code === "unoffered" ? code : `!${code}`);
	if (issue != null && waitsOnSource(issue)) said.push("waits");
	if (read) said.push("read");
	return said.join(" ");
}

Deno.test("the table names every event at each standing it starts from", () => {
	for (const [start, cells] of Object.entries(table)) {
		assertEquals(start in starts, true, `${start} is a standing`);
		assertEquals(Object.keys(cells), Object.keys(events));
	}
});

const shares = new LandingTable("share");
for (const [start, cells] of Object.entries(table)) {
	for (const [event, cell] of Object.entries(cells)) {
		if (cell == null) {
			shares.leave("the event cannot reach a new access's read");
			continue;
		}
		const [said, reason] = typeof cell === "string" ? [cell, null] : cell;
		shares.row(`a share ${start}, then ${event}: ${said}`, {
			start: async () => {
				// Only a source that may delegate is offered a narrower control.
				const f = await reach(start, { delegates: event.startsWith("make a narrower") });
				return { f, reads: f.plan.reads };
			},
			event: ({ f }) => events[event](f),
			settle: () => settle(),
			landing: ({ f, reads }, met) => standing(f, met, event.includes("new access read") && f.plan.reads > reads),
			expected: said,
			// The card says the reason, then the failure behind it when there is one.
			check: ({ f }) => {
				if (reason == null) return;
				const words = refusalText(new LocalRefusal(reason));
				assert(
					f.management.issue?.reason.startsWith(words) === true,
					`${f.management.issue?.reason} says ${words}`,
				);
			},
			page: ({ f }) => f,
		});
	}
}
// Every standing meets each event, so the two that make a narrower control from
// the source add a row at each of the nine standings.
shares.pin(Object.keys(table).length * Object.keys(events).length, 181, {
	"the event cannot reach a new access's read": 26,
});

// The page offers only what can work at each standing, and the source's row
// always leads back to the share's card.
for (const [start, offered] of Object.entries(offeredAt)) {
	Deno.test(`a share ${start} offers ${offered.join(", ")}`, async () => {
		const f = await reach(start);
		assertEquals(offers(f), [...offered]);
		assertEquals(rowOffers(f.management, f.sourceRow()).share?.kind, "resume");
		await closedClean(f);
	});
}

// A share that ended leaves the page free to share again from the same source.
const ends: Record<string, (f: Page) => Promise<unknown>> = {
	"its review closed": async (f) => {
		await stand(f, "conflict");
		await f.management.discardIssue();
		f.plan.answer = "committed";
	},
	"its link shown and its card closed": async (f) => {
		await stand(f, "linked");
		await f.management.discardIssue();
	},
	"its connection lost and its card closed": async (f) => {
		await stand(f, "lost");
		await f.management.discardIssue();
		f.plan.sources.push(restored(f));
		await f.management.reachAgain(f.sourceRow());
	},
};
for (const [end, bring] of Object.entries(ends)) {
	Deno.test(`a second share after the first had ${end} is made`, async () => {
		const f = await page();
		await prepareShare(f);
		await bring(f);
		await prepareShare(f);
		await f.management.goOnIssue();
		assertEquals(standing(f, [], false), "committed done");
		await closedClean(f);
	});
}
Deno.test("a Try now on a share's new access whose source stays unreached is answered on the row pressed", async () => {
	const f = await reach("unreached, source lost");
	f.plan.sources.push(unreached);
	const pressed = made(f);
	const failure = await f.management.reachAgain(pressed).then(() => null, (error: unknown) => error);
	await f.moved();
	const source = f.sourceRow();
	assert(failure != null, "the press is answered");
	assert(rowShows(source, failure), "the source's row says its own failure");
	assert(!rowShows(pressed, failure), "the pressed row says it only as the press's answer");
	await closedClean(f);
});
Deno.test("a closed page starts no second share", async () => {
	const f = await reach("linked");
	const source = f.sourceRow();
	assert(described(source), "the source is described");
	await closedClean(f);
	assertEquals(
		await refused(() => f.management.prepareIssue(source, ["observeWorkspace"], "again", false, 0, noCeilings)),
		"local-session-closed",
	);
});
const replayAnswers: ("refused" | "conflict")[] = ["refused", "conflict"];
for (const answer of replayAnswers) {
	Deno.test(`a share whose new access is asked for again and ${answer} ends, saying the access was made`, async () => {
		const f = await reach("unreached");
		f.plan.answer = answer;
		assertEquals(await refused(() => f.management.goOnIssue()), null);
		assertEquals(standing(f, [], false), "lost done");
		assert(
			f.management.issue?.reason.startsWith(refusalText(new LocalRefusal("access-share-lost"))),
			"it says why",
		);
		assertEquals(offers(f), ["finish", "remove the source"]);
		await closedClean(f);
	});
}
Deno.test("a share's ending blames no dropped connection, because a timeout ends one the same way", () => {
	const endings: LocalRefusalKey[] = [
		"access-share-lost",
		"access-share-lost-removed",
		"access-share-lost-unknown",
		"access-share-unlinked",
		"access-share-unheld",
		"access-share-unsent",
	];
	for (const key of endings) {
		assert(!/connection/i.test(refusalText(new LocalRefusal(key))), `${key} names a cause it cannot know`);
	}
});
