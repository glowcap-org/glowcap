// Submission uncertainty stops at the commit point. Later failures keep it.
/// <reference lib="dom" />
import { closed, everyReached, noCeilings } from "../support/managed_link.ts";
import "../support/match_media.ts";
import { assert, assertEquals } from "@std/assert";
import { described, reached } from "../../web/ui/session/managed/held_control.ts";
import { deferred, viewer } from "../support/managed_viewer.ts";
import { settle } from "../support/wait.ts";
import { LocalRefusal, refusalText } from "../../lib/text/failure.ts";

async function fixture(
	submitOutcome: () => Promise<unknown>,
	describeIssued = () => Promise.resolve({ available: false }),
) {
	const request = { submitOutcome, free() {} };
	const source = {
		describe: () => Promise.resolve({ available: true, revision: "1" }),
		prepareIssue: () => Promise.resolve(request),
		prepareLabel: () => Promise.resolve(request),
		free() {},
	};
	const session = viewer({}, () => {}, { savedControl: () => Promise.resolve(source) });
	await session.management.restore(["source"], everyReached);
	const control = session.management.held[0];
	assert(control != null && described(control));
	const issued = { describe: describeIssued, free() {} };
	return { session, management: session.management, control, issued };
}

for (const kind of ["issue", "edit"]) {
	for (const known of [true, false]) {
		Deno.test(`access ${kind} preserves a ${known ? "known refusal" : "submission interruption"}`, async () => {
			const error = known ? new LocalRefusal("session-closed") : new Error("submission interrupted");
			const f = await fixture(() => Promise.reject(error));
			try {
				if (kind === "issue") await f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings);
				else await f.management.prepare(f.control, { kind: "label", label: "test" }, "1");
				const [outcome] = await Promise.allSettled([
					kind === "issue" ? f.management.submitIssue() : f.management.submit(f.control),
				]);
				if (known) {
					assert(outcome.status === "rejected");
					assert(outcome.reason === error, "a local refusal must keep its identity");
				} else {
					assert(outcome.status === "fulfilled");
					assertEquals(outcome.value.phase, "uncertain");
					assertEquals(
						"reason" in outcome.value ? outcome.value.reason : null,
						refusalText(
							new LocalRefusal(kind === "issue" ? "access-issue-unknown" : "access-edit-unknown", {
								cause: error,
							}),
						),
					);
				}
			} finally {
				await f.session.close();
			}
		});
	}
}

Deno.test("a committed issuance whose new access fails its first read holds it with that failure, and asks again", async () => {
	let fails = true;
	const diagnostic = new Error("inspection disconnected");
	const f = await fixture(
		() => Promise.resolve(returned),
		() => fails ? Promise.reject(diagnostic) : Promise.resolve({ available: false }),
	);
	const returned = { status: "committed", access: { free() {} }, control: f.issued };
	try {
		await f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings);
		const first = await f.management.submitIssue();
		assertEquals([first.phase, first.reason], ["committed", ""]);
		const made = f.management.issued;
		assert(made != null && made.state.kind !== "reached", "the new access is held unreached");
		assert(made.state.failure === diagnostic, "its row says the actual read failure");
		fails = false;
		Object.assign(f.control.state.kind === "reached" ? f.control.state.handle : {}, {
			resumeIssue: () => ({ submitOutcome: () => Promise.resolve(returned), free() {} }),
		});
		const recovered = await f.management.submitIssue();
		assertEquals([recovered.phase, recovered.reason], ["committed", ""]);
		assertEquals(f.management.issued?.state.kind, "reached", "asking again holds it");
	} finally {
		await f.session.close();
	}
});

Deno.test("a session closing during issuance refuses without claiming an uncertain result", async () => {
	const pending = deferred<unknown>();
	const f = await fixture(() => pending.promise);
	await f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings);
	const submitted = f.management.submitIssue();
	// The send starts in its turn, and the session closes while it waits.
	await settle();
	f.management.stop();
	let freed = 0;
	const wrapper = {
		free() {
			freed++;
		},
	};
	pending.resolve({ status: "committed", access: wrapper, control: wrapper });
	const [result] = await Promise.allSettled([submitted]);
	assert(result.status === "rejected" && result.reason instanceof LocalRefusal);
	assertEquals(result.reason.code, "local-session-closed");
	assertEquals(freed, 2);
	await f.session.close();
});

Deno.test("issuance without a control revision says unavailable instead of changed", async () => {
	const f = await fixture(() => Promise.resolve({ status: "committed" }));
	delete f.control.state.powers.revision;
	try {
		const [result] = await Promise.allSettled([
			f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings),
		]);
		assert(result.status === "rejected" && result.reason instanceof LocalRefusal);
		assertEquals(result.reason.code, "local-access-unavailable");
	} finally {
		await f.session.close();
	}
});

/** The markup of the `kind` card over `f`'s control. */
async function card(f: Awaited<ReturnType<typeof fixture>>, kind: "issue" | "edit"): Promise<string> {
	const { createElement: h } = await import("react");
	const { renderToStaticMarkup } = await import("react-dom/server");
	const { SessionIssueModal } = await import("../../web/ui/settings/SessionIssue.tsx");
	const { SessionGrantEditModal } = await import("../../web/ui/settings/SessionGrantEdit.tsx");
	const { ManagedSessionProvider } = await import("../../web/ui/session/managed/context.tsx");
	const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
	const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
	const { ModalProvider } = await import("../../web/ui/modal.ts");
	const { CommitmentProvider } = await import("../../web/ui/commitment.tsx");
	const { RoomsPage } = await import("../../web/ui/page.ts");
	const controller = createRoomsBrowserController(
		new RoomsPage(),
		() => {},
		() => "/",
		() => Promise.resolve({ session: f.session, local: true }),
	);
	return renderToStaticMarkup(
		h(
			RoomsBrowserProvider,
			{ value: controller },
			h(
				ModalProvider,
				null,
				h(
					CommitmentProvider,
					null,
					h(
						ManagedSessionProvider,
						{ value: f.session },
						h(kind === "issue" ? SessionIssueModal : SessionGrantEditModal, {
							control: f.control,
							open: true,
							onClose() {},
						}),
					),
				),
			),
		),
	);
}

Deno.test("a share whose source lost its connection says it waits on the source, and holds its send until it is reached", async () => {
	const { createElement: h } = await import("react");
	const { renderToStaticMarkup } = await import("react-dom/server");
	const { managedAccessText: text } = await import("../../lib/text/managed_access.ts");
	const shown = (said: string) => renderToStaticMarkup(h("span", null, said)).slice(6, -7);
	const f = await fixture(() => Promise.resolve({ status: "committed" }));
	try {
		await f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings);
		Object.assign(reached(f.control), { describe: () => Promise.reject(closed()) });
		const lost = await f.management.refresh(f.control).then(() => null, (error: unknown) => error);
		assert(lost != null && f.control.state.kind === "unreached", "the source is unreached");
		const html = await card(f, "issue");
		assert(html.includes(shown(text.issueSourceUnreached)), "the card says the share waits on its source");
		const create = html.match(/<button[^>]*aria-describedby="sessionIssueWaiting"[^>]*>/)?.[0] ?? "";
		assert(create.includes("disabled"), `the share's send waits on its source: ${create}`);
		assert(html.includes(shown(text.create)), "the share's send is shown");
	} finally {
		await f.session.close();
	}
});

for (const phase of ["conflict", "uncertain"]) {
	const kinds: ("issue" | "edit")[] = ["issue", "edit"];
	for (const kind of kinds) {
		Deno.test(`the ${kind} dialog renders its ${phase} reason once beside its recovery action`, async () => {
			const { createElement: h } = await import("react");
			const { renderToStaticMarkup } = await import("react-dom/server");
			const { managedAccessText: text } = await import("../../lib/text/managed_access.ts");
			const f = await fixture(() => Promise.resolve({ status: phase }));
			try {
				if (kind === "issue") await f.management.prepareIssue(f.control, [], "test", false, 0, noCeilings);
				else await f.management.prepare(f.control, { kind: "label", label: "test" }, "1");
				const outcome = kind === "issue"
					? await f.management.submitIssue()
					: await f.management.submit(f.control);
				const html = await card(f, kind);
				const said = renderToStaticMarkup(h("span", null, "reason" in outcome ? outcome.reason : "")).slice(
					6,
					-7,
				);
				assert(said.length > 0);
				assertEquals(html.split(said).length, 2, "one owner supplies the explanation");
				const button = kind === "issue"
					? phase === "conflict" ? text.reviewIssuer : text.recoverIssue
					: phase === "conflict"
					? text.reapply
					: text.recoverEdit;
				assert(html.includes(button), `missing recovery action ${button}`);
			} finally {
				await f.session.close();
			}
		});
	}
}

Deno.test("a changed grant identity refuses inspection rather than adopting another grant", async () => {
	const f = await fixture(() => Promise.resolve({ status: "conflict" }));
	const grant = {
		slot: 1,
		generation: "1",
		revision: "1",
		label: "held",
		status: "active",
		effectiveStatus: "active",
		configured: { permissions: [], bounds: [] },
		ceiling: { permissions: [], bounds: [] },
		delegationDepth: 0,
	} satisfies import("../../web/ui/session/managed/access_powers.ts").GrantView;
	f.control.state = { ...f.control.state, grant };
	reached(f.control).describe = () => Promise.resolve({ available: true, inspect: true });
	reached(f.control).inspect = () => Promise.resolve({ ...grant, generation: "2" });
	try {
		const [result] = await Promise.allSettled([f.management.refresh(f.control)]);
		assert(result.status === "rejected" && result.reason instanceof LocalRefusal);
		assertEquals(result.reason.code, "local-access-changed");
		assert(f.control.state.grant === grant);
	} finally {
		await f.session.close();
	}
});

Deno.test("reapplying after control revocation keeps the conflict and names unavailable access", async () => {
	const f = await fixture(() => Promise.resolve({ status: "conflict" }));
	await f.management.prepare(f.control, { kind: "label", label: "test" }, "1");
	await f.management.submit(f.control);
	reached(f.control).describe = () => Promise.resolve({ available: false });
	try {
		const [result] = await Promise.allSettled([f.management.reapply(f.control)]);
		assert(result.status === "rejected" && result.reason instanceof LocalRefusal);
		assertEquals(result.reason.code, "local-access-unavailable");
		assertEquals(f.control.edit?.phase, "conflict");
	} finally {
		await f.session.close();
	}
});

for (
	const phase of [
		"conflict",
		"uncertain",
	] satisfies import("../../web/ui/session/managed/share_state.ts").PendingIssue["phase"][]
) {
	Deno.test(`a new issuance failure has failure styling over a held ${phase}`, async () => {
		const { createElement: h } = await import("react");
		const { renderToStaticMarkup } = await import("react-dom/server");
		const { ModalProvider } = await import("../../web/ui/modal.ts");
		const { IssueReply } = await import("../../web/ui/settings/SessionIssue.tsx");
		const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
		const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
		const { RoomsPage } = await import("../../web/ui/page.ts");
		const session = viewer({});
		const browser = createRoomsBrowserController(
			new RoomsPage(),
			() => {},
			() => "/",
			() => Promise.resolve({ session, local: true }),
		);
		const render = (failure: string) =>
			renderToStaticMarkup(
				h(
					RoomsBrowserProvider,
					{ value: browser },
					h(ModalProvider, null, h(IssueReply, { failure, issue: { phase, reason: "older outcome" } })),
				),
			);
		try {
			const failed = render("new failure");
			assert(failed.includes('data-kind="failure"'));
			assert(!failed.includes("older outcome"));
			assert(render("").includes('data-kind="warning"'));
		} finally {
			await session.close();
		}
	});
}

Deno.test("closing the share card drops only a form it has not sent, so a press waiting behind a turn never holds it open", async () => {
	const { holdsUnsent } = await import("../../web/ui/settings/SessionIssue.tsx");
	assertEquals(holdsUnsent(false, null, true), true, "an unsent form asks before it is dropped");
	assertEquals(holdsUnsent(false, null, false), false, "an untouched form closes at once");
	assertEquals(holdsUnsent(true, null, true), false, "a form being sent closes at once");
});
