// Held management keeps its exact custody: issuance and close settle returned
// handles once, and what a viewer knows about an access survives the control
// losing sight of it. Rust browser proofs separately exercise actual authority.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assert, assertEquals } from "../assert.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import { sessionTryNow } from "../../lib/text/page.ts";
import { ROOMS_FAILURES, type RoomsErrorCode } from "../../lib/failure_data.ts";
import { reachFailure } from "../support/browser_failure.ts";
import { fixture } from "../support/managed_controller.ts";
import { editSaid, fakeHandle, noCeilings } from "../support/managed_link.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import { RoomsProjectionProvider } from "../../web/ui/hooks.ts";
import { ManagedAccess } from "../../web/ui/session/managed/access.ts";
import { knownLabel } from "../../web/ui/session/managed/held_control.ts";
import {
	type GrantView,
	keptPowers,
	type ManagementView,
	NO_MANAGEMENT,
	usableGrants,
} from "../../web/ui/session/managed/access_powers.ts";
import type { DescribedControl, HeldControl } from "../../web/ui/session/managed/held_control.ts";
import type { EditIntent, EditState } from "../../web/ui/session/managed/edit_state.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedControl,
	RoomsManagedEdit,
	RoomsManagedIssuance,
	RoomsManagedWorkspace,
} from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { PendingIssue } from "../../web/ui/session/managed/share_state.ts";
import { deferred } from "../support/managed_viewer.ts";
import { settle } from "../support/wait.ts";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import { managedAccessText as text, unreachedAccess } from "../../lib/text/managed_access.ts";

const { SessionGrantEditModal } = await import("../../web/ui/settings/SessionGrantEdit.tsx");
const { SessionAccessModal } = await import("../../web/ui/settings/SessionAccess.tsx");
const { SessionIssueModal } = await import("../../web/ui/settings/SessionIssue.tsx");
const { ManagedSessionProvider } = await import("../../web/ui/session/managed/context.tsx");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { ModalProvider } = await import("../../web/ui/modal.ts");
const { CommitmentProvider } = await import("../../web/ui/commitment.tsx");

/** A saved control `id` reached through `handle`, whose last description said
 * `powers`, for an access with no binding behind it. */
function reachedControl(
	handle: Partial<RoomsManagedControl>,
	powers: Partial<ManagementView> = {},
	id = "held",
): DescribedControl {
	return {
		id,
		storage: { kind: "saved" },
		state: {
			kind: "reached",
			handle: fakeHandle<RoomsManagedControl>(handle),
			grant: null,
			powers: { available: true, ...powers },
		},
	};
}

/** `handle`, held by `access` under `id`, reached and read as `powers`. A
 * share starts only from an access its owner holds. */
function heldBy(
	access: ManagedAccess,
	handle: Partial<RoomsManagedControl>,
	powers: Partial<ManagementView> = {},
	id = "held",
): Promise<HeldControl> {
	return access.hold(
		id,
		fakeHandle<RoomsManagedControl>({
			describe: () => Promise.resolve({ ...NO_MANAGEMENT, available: true, ...powers }),
			free() {},
			...handle,
		}),
	);
}

/** Held management with no binding behind it, over `workspace`. */
function bareAccess(workspace: Partial<RoomsManagedWorkspace> = {}): ManagedAccess {
	return new ManagedAccess(
		fakeHandle<RoomsManagedApplication>({}),
		fakeHandle<RoomsManagedWorkspace>(workspace),
		() => {},
		() => {},
	);
}

const intentKinds: EditIntent["kind"][] = ["label", "policy", "pause", "resume", "revoke"];
const recoveries: ("conflict" | "uncertain")[] = ["conflict", "uncertain"];
for (const kind of intentKinds) {
	for (const phase of recoveries) {
		Deno.test(`a revoked control keeps ${phase} recovery for its original ${kind} edit`, () => {
			const intent: EditIntent = kind === "label"
				? { kind, label: "My draft" }
				: kind === "policy"
				? { kind, permissions: [] }
				: { kind };
			const reason = "original diagnostic";
			const edit: EditState = phase === "conflict"
				? { phase, intent, reason }
				: { phase, intent, base: "1", reason, request: fakeHandle<RoomsManagedEdit>({}) };
			const control: DescribedControl = {
				...reachedControl({}, { available: false }, "ended"),
				committed: { label: "Previously known", permissions: [] },
				edit,
			};
			const html = renderToStaticMarkup(createElement(
				RoomsBrowserProvider,
				{ value: fakeHandle<RoomsBrowserController>({}) },
				createElement(
					ModalProvider,
					null,
					createElement(
						CommitmentProvider,
						null,
						createElement(
							ManagedSessionProvider,
							{
								value: fakeHandle<ManagedRoomsSession>({
									management: fakeHandle<ManagedAccess>({ removal: () => null }),
								}),
							},
							createElement(SessionGrantEditModal, { control, open: true, onClose() {} }),
						),
					),
				),
			));
			assert(html.includes("original diagnostic"), "revocation hid the original refusal");
			const label = phase === "conflict" ? text.discard : text.recoverEdit;
			const button = html.match(new RegExp(`<button([^>]*)>${label}</button>`));
			assert(button != null && !button[1].includes("disabled"), "revocation stranded the retained request");
		});
	}
}

Deno.test("a second press waits its turn, and close drains returned custody exactly once", async () => {
	const result = deferred<unknown>();
	let submissions = 0;
	let freed = 0;
	const request = {
		submitOutcome: () => {
			submissions++;
			return result.promise;
		},
		free: () => freed++,
	};
	const access = bareAccess();
	const source = await heldBy(access, { prepareIssue: () => Promise.resolve(request) }, { revision: "1" });
	await access.prepareIssue(source, [], "original", false, 0, { editCeiling: null, issueCeiling: null });
	const first = access.submitIssue();
	const second = access.submitIssue();
	await settle();
	assertEquals(submissions, 1, "the second press waits for the first to end");
	access.stop();
	let closed = false;
	const closing = access.close().then(() => {
		closed = true;
	});
	await settle();
	assertEquals(
		[closed, freed],
		[false, 0],
		"close must not free a request while its submission owns returned wrappers",
	);
	const wrapper = { free: () => freed++ };
	result.resolve({ status: "committed", access: wrapper, control: wrapper });
	const outcomes = await Promise.allSettled([first, second]);
	await closing;
	for (const outcome of outcomes) {
		assert(
			outcome.status === "rejected" && outcome.reason instanceof LocalRefusal,
			"closed session refuses each caller",
		);
		assertEquals(outcome.reason.code, "local-session-closed");
	}
	assertEquals(freed, 3);
	await access.close();
	assertEquals(freed, 3);
});

Deno.test("managed close drains a control description without adopting late custody", async () => {
	const description = deferred<unknown>();
	let freed = 0;
	const access = bareAccess();
	const handle = fakeHandle<RoomsManagedControl>({ describe: () => description.promise, free: () => freed++ });
	const holding = access.hold("late", handle).catch(() => {
		handle.free();
	});
	const closing = access.close();
	description.resolve({ available: false });
	await Promise.all([holding, closing]);
	assertEquals(access.held.length, 0);
	assertEquals(freed, 1);
});

Deno.test("a revoked access is left out of what an access was used to create", () => {
	const row = (label: string, effectiveStatus: GrantView["effectiveStatus"]): GrantView => ({
		slot: 1,
		generation: "1",
		revision: "1",
		label,
		status: effectiveStatus,
		effectiveStatus,
		configured: { permissions: [], bounds: [] },
		ceiling: { permissions: [], bounds: [] },
		delegationDepth: 0,
	});
	const shown = usableGrants([row("ended", "revoked"), row("on", "active"), row("held", "paused")]);
	assertEquals(shown.map((grant) => grant.label), ["on", "held"]);
});

Deno.test("the issuer keeps every power its source can pass on", async () => {
	let sent: unknown = null;
	const request = { submitOutcome: () => new Promise(() => {}), free() {} };
	const access = bareAccess();
	const grant = {
		slot: 1,
		generation: "1",
		revision: "1",
		label: "held",
		status: "active",
		effectiveStatus: "active",
		configured: { permissions: ["observeWorkspace"], bounds: [] },
		ceiling: { permissions: ["observeWorkspace"], bounds: [] },
		delegationDepth: 0,
	} satisfies GrantView;
	const source = await heldBy(
		access,
		{
			inspect: () => Promise.resolve(grant),
			prepareIssue: (_base, _permissions, _label, _paused, _depth, powers) => {
				sent = JSON.parse(powers);
				return Promise.resolve(request);
			},
		},
		{ revision: "1", delegateControl: true, inspect: true, pause: true, resume: true, revoke: false },
	);
	await access.prepareIssue(source, ["observeWorkspace"], "kept", false, 0, {
		editCeiling: ["observeWorkspace"],
		issueCeiling: null,
	});
	assertEquals(sent, {
		inspect: true,
		pause: true,
		resume: true,
		revoke: false,
		delegateControl: true,
		editCeiling: ["observeWorkspace"],
		issueCeiling: null,
	});
	assertEquals(keptPowers({ available: true, inspect: true }, { editCeiling: [], issueCeiling: [] }), NO_MANAGEMENT);
	await access.close();
});

Deno.test("a committed issuance rereads its source, so the next one starts from its new revision", async () => {
	let revision = "1";
	const bases: unknown[] = [];
	const issued = { describe: () => Promise.resolve({ available: false }), free() {} };
	const request = {
		submitOutcome: () => {
			revision = String(Number(revision) + 1);
			const access = { publish: () => Promise.resolve("the access link"), free() {} };
			return Promise.resolve({ status: "committed", access, control: issued });
		},
		free() {},
	};
	const access = bareAccess();
	const source = await heldBy(
		access,
		{
			describe: () => Promise.resolve({ available: true, revision }),
			prepareIssue: (base) => {
				bases.push(base);
				return Promise.resolve(request);
			},
		},
		{ revision },
		"current",
	);
	await access.prepareIssue(source, ["observeWorkspace"], "first", false, 0, noCeilings);
	assertEquals((await access.submitIssue()).phase, "committed");
	const made = access.issued;
	assert(made != null, "the issue made a control");
	made.storage = { kind: "saved" };
	await access.publishIssue();
	await access.discardIssue();
	await access.prepareIssue(source, ["observeWorkspace"], "second", false, 0, noCeilings);
	assertEquals(bases, ["1", "2"]);
	await access.close();
});

Deno.test("a committed label is known even to a control that cannot inspect", async () => {
	const access = bareAccess();
	const control = reachedControl(
		{
			prepareLabel: () =>
				Promise.resolve({ submitOutcome: () => Promise.resolve({ status: "committed" }), free() {} }),
		},
		{ revision: "1", editCeiling: { permissions: [], bounds: [] } },
		"blind",
	);
	await access.prepare(control, { kind: "label", label: "Home" }, "1");
	assertEquals(editSaid(await access.submit(control)), "committed");
	assertEquals(knownLabel(control), "Home");
	await access.close();
});

/** Forgetting "pasted" over a workspace whose release answers with each of
 * `answers` in turn: conflict, committed, or refused. */
async function forgetting(...answers: string[]) {
	let attempts = 0;
	let freed = 0;
	const workspace = {
		prepareForgetControl: () => {
			const status = answers[attempts++];
			return Promise.resolve({
				submit: () => Promise.resolve({ status, reason: "the session refused it" }),
				free: () => freed++,
			});
		},
	};
	const access = bareAccess(workspace);
	const handle = fakeHandle<RoomsManagedControl>({
		describe: () => Promise.resolve({ ...NO_MANAGEMENT, available: false }),
		free() {},
	});
	const control = await access.hold("pasted", handle);
	const forgotten = await access.forget(control).then(() => null, (error: unknown) => error);
	const held = access.held.includes(control);
	await access.close();
	return { forgotten, held, attempts, freed };
}

Deno.test("forgetting an access rereads the workspace after a conflict, and three conflicts in a row say so", async () => {
	assertEquals(await forgetting("conflict", "conflict", "committed"), {
		forgotten: null,
		held: false,
		attempts: 3,
		freed: 3,
	});
	const conflicted = await forgetting("conflict", "conflict", "conflict", "committed");
	assert(conflicted.forgotten instanceof LocalRefusal, String(conflicted.forgotten));
	assertEquals(
		[conflicted.forgotten.code, conflicted.held, conflicted.attempts],
		["local-acquisition-conflict", true, 3],
	);
	const refused = await forgetting("refused");
	assert(refused.forgotten instanceof Error, String(refused.forgotten));
	assertEquals(
		[refused.forgotten.message, refused.held, refused.attempts],
		["the session refused it", true, 1],
		"a refusal is not tried again",
	);
});

/** The access card's markup for one held access the page's link could not
 * reach, described before unless `never` says it never was. */
function unreachedCard(failure: unknown, never = false): string {
	const control: HeldControl = {
		id: "down",
		state: never
			? { kind: "undescribed", failure }
			: { kind: "unreached", failure, grant: null, powers: { available: true } },
		storage: { kind: "saved" },
	};
	const management = fakeHandle<ManagedAccess>({
		held: [control],
		issue: null,
		removal: () => null,
		subscribe: () => () => {},
		getVersion: () => 0,
	});
	return rendered(management, createElement(SessionAccessModal, { open: true, onClose() {} }));
}
/** The markup of `card` over `management`, as a person reads it. */
function rendered(management: ManagedAccess, card: ReturnType<typeof createElement>): string {
	const { page } = fixture();
	// Server rendering reads the fixture state as its initial snapshot.
	page.projection.api.getInitialState = page.projection.api.getState;
	const html = renderToStaticMarkup(createElement(
		RoomsProjectionProvider,
		{ value: page.projection },
		createElement(
			RoomsBrowserProvider,
			{ value: fakeHandle<RoomsBrowserController>({}) },
			createElement(
				ModalProvider,
				null,
				createElement(
					CommitmentProvider,
					null,
					createElement(
						ManagedSessionProvider,
						{ value: fakeHandle<ManagedRoomsSession>({ management }) },
						card,
					),
				),
			),
		),
	));
	return html.replaceAll("&#x27;", "'");
}

Deno.test("a prepared share's card shows what it was prepared with, locked", () => {
	const source = reachedControl({}, { revision: "1" });
	const issue: PendingIssue = {
		id: "share",
		source,
		terms: {
			permissions: ["observeWorkspace", "presence"],
			label: "kept label",
			paused: true,
			depth: 3,
			powers: NO_MANAGEMENT,
		},
		reason: "",
		phase: "prepared",
		request: fakeHandle<RoomsManagedIssuance>({}),
	};
	const management = fakeHandle<ManagedAccess>({
		held: [source],
		issue,
		subscribe: () => () => {},
		getVersion: () => 0,
	});
	const html = rendered(management, createElement(SessionIssueModal, { control: source, open: true, onClose() {} }));
	const field = (id: string) => html.match(new RegExp(`<input[^>]*id="${id}"[^>]*>`))?.[0] ?? "";
	const label = field("sessionAccessLabel");
	const depth = field("sessionDelegationDepth");
	assert(label.includes('value="kept label"') && label.includes("disabled"), `the kept label, locked: ${label}`);
	assert(depth.includes('value="3"') && depth.includes("disabled"), `the kept depth, locked: ${depth}`);
});

/** Each way a restore of a saved access can fail, and whether its row offers
 * Try now: only where asking again from this browser can meet the change. */
const restoreFailures: [RoomsErrorCode, boolean][] = [
	["session-unreachable", true],
	["session-request-timed-out", true],
	// A saved control whose dial never got its turn before the bound: its
	// session was never asked.
	["session-not-reached-yet", true],
	["session-restoration-failed", true],
	["saved-transport-unavailable", false],
	["session-capability-gone", false],
];
for (const [code, offered] of restoreFailures) {
	Deno.test(`an access a restore could not reach with ${code} says so on its row in its own words`, () => {
		const failure = reachFailure("the restore's answer", code);
		const said = unreachedAccess.get(code);
		assert(said != null, `${code} has its own words on an access row`);
		const html = unreachedCard(failure);
		const steps = [said.action, offered ? null : text.removeInManage].filter((step) => step != null).join(" ");
		assert(html.includes(`${said.summary} ${steps} (${code}: the restore's answer)`), "the row says why");
		assertEquals(html.includes(`>${sessionTryNow}</button>`), offered, "Try now shows only where it can help");
	});
}

Deno.test("an access that failed with a code the row does not name says that failure in its own words", () => {
	const code = "transport-not-dialed";
	const html = unreachedCard(reachFailure("the restore's answer", code));
	const said = ROOMS_FAILURES[code];
	assert(html.includes(`${said.summary} ${said.action} (${code}: the restore's answer)`), "the row says why");
	assert(
		!html.includes(unreachedAccess.get("session-unreachable")?.summary ?? ""),
		"it names no session it did not try",
	);
	assert(html.includes(`>${sessionTryNow}</button>`), "a failure that may clear can be tried again");
});

for (const never of [false, true]) {
	Deno.test(`an access the link could not reach, ${never ? "never" : "once"} described, offers ${never ? "removal" : "its card"}`, () => {
		const html = unreachedCard(new Error("the session did not answer"), never);
		assert(html.includes(`>${text.held}</span>`), "the row is named");
		assert(html.includes(`>${sessionTryNow}</button>`), "the row can be reached again");
		// A control never reached knows nothing it could manage.
		assertEquals(html.includes(`>${text.manage}</button>`), !never);
		assertEquals(html.includes(`>${text.remove}</button>`), never);
	});
}

for (
	const [code, tried] of [["session-unreachable", true], ["session-capability-gone", false]] satisfies [
		string,
		boolean,
	][]
) {
	Deno.test(`a new share's card over a source unreached with ${code} waits, naming Try now only where its row offers it`, () => {
		const source: DescribedControl = {
			id: "down",
			state: {
				kind: "unreached",
				failure: reachFailure("the reach's answer", code),
				grant: null,
				powers: { available: true, issueCeiling: { permissions: ["observeWorkspace"], bounds: [] } },
			},
			storage: { kind: "saved" },
		};
		const management = fakeHandle<ManagedAccess>({
			held: [source],
			issue: null,
			subscribe: () => () => {},
			getVersion: () => 0,
		});
		const html = rendered(
			management,
			createElement(SessionIssueModal, { control: source, open: true, onClose() {} }),
		);
		const create = html.match(/<button[^>]*aria-describedby="sessionIssueWaiting"[^>]*>/)?.[0] ?? "";
		assert(create.includes("disabled"), `the share waits on its source: ${create}`);
		assertEquals(html.includes(sessionTryNow), tried, "the card names Try now only where the row offers it");
	});
}
