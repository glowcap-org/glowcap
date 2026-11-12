// A selected authority and its owning settings remain fenced through admission.
import { LOCAL_REFUSALS } from "../../lib/text/local_refusals.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";

await initializeApplication();

for (const front of ["command", "action"] as const) {
	Deno.test(`${front} captures its selected authority before its first asynchronous read`, async () => {
		let current = snapshot();
		current.intent.directories.push({
			id: "dir",
			access: "old",
			nick: "ada",
			nickAllocation: "exact",
			home: true,
			standing: null,
		});
		let prepared = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: () => {
				prepared++;
				throw new Error("must not prepare");
			},
		});
		await session.refresh();
		const result = Promise.allSettled([
			front === "command"
				? session.command("setDirectoryStanding", ["dir", "away"])
				: session.actions.run("setDirectoryStanding", ["dir", "away"]),
		]);
		current = structuredClone(current);
		current.revision = "2";
		current.intent.directories[0].access = "replacement";
		const [outcome] = await result;
		assertEquals(outcome.status, "rejected");
		if (outcome.status === "rejected") {
			assert(
				outcome.reason.message === LOCAL_REFUSALS["command-selection-changed"].summary,
				"refuse the retired authority before preparation",
			);
		}
		assertEquals(prepared, 0);
		assertEquals(session.pending, []);
		await session.close();
	});
}

for (const keep of [false, true]) {
	for (const change of ["room startup", "retention choice", "erasure"] as const) {
		Deno.test(`history ${keep}: admission fences ${change} at the retention owner`, async () => {
			let current = snapshot();
			current.intent.keepHistory = !keep;
			current.intent.conversations.push({
				kind: "room",
				id: "room",
				directory: "directory",
				source: "source",
				access: "access",
				name: "room",
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			let prepared = 0;
			const session = viewer({
				snapshot: () => Promise.resolve(current),
				prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
					prepared++;
					return Promise.resolve({
						originalIntent: () => [id, Number(revision), name, args],
						submit: () => Promise.resolve({ status: "committed" }),
						status: () => Promise.resolve("committed"),
						free() {},
					});
				},
			});
			try {
				await session.refresh();
				const work = Promise.allSettled([session.command("chooseHistoryRetention", [String(keep)])]);
				current = structuredClone(current);
				current.revision = "2";
				if (change === "room startup") current.intent.conversations[0].inbox = "callback";
				else if (change === "retention choice") current.intent.keepHistory = keep;
				else current.intent.historyErasure = "original-erasure";
				const [outcome] = await work;
				assertEquals(outcome.status, change === "room startup" ? "fulfilled" : "rejected");
				assertEquals(prepared, change === "room startup" ? 1 : 0);
				if (outcome.status === "fulfilled") session.finish(outcome.value);
				if (outcome.status === "rejected") {
					assert(
						outcome.reason.message === LOCAL_REFUSALS["command-selection-changed"].summary,
						"the changed retention owner refuses admission",
					);
				}
			} finally {
				await session.close();
			}
		});
	}
}

for (const level of ["global", "directory", "room"] as const) {
	Deno.test(`effective standing projects and conflicts at its ${level} owner`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			source: "source",
			access: "access",
			standing: level === "directory" ? "here" : null,
			nick: "reader",
			nickAllocation: "exact",
			home: true,
		});
		current.intent.conversations.push({
			kind: "room",
			id: "room",
			directory: "directory",
			source: "room-source",
			access: "room-access",
			name: "room",
			control: null,
			reconnect: "requested",
			standing: level === "room" ? "here" : null,
			draft: "",
		});
		const session = viewer({ snapshot: () => Promise.resolve(current) });
		await session.refresh();
		const name = level === "global"
			? "setStanding"
			: level === "directory"
			? "setDirectoryStanding"
			: "setRoomStanding";
		const target = level === "global" ? null : level;
		assertEquals(session.effects.roomStandingPending("room"), false);
		session.effects.reserve("effective", "setEffectiveStanding", ["room", "away"]);
		assertEquals(session.effects.roomStandingPending("room"), level === "room");
		assertEquals(session.effects.roomStandingPending("other-room"), false);
		assertEquals(session.effects.standing(name, target, "here"), "away");
		let refusal = "";
		try {
			session.effects.reserve("other", name, target == null ? ["here"] : [target, "here"]);
		} catch (error) {
			refusal = String(error);
		}
		assert(
			refusal.includes(LOCAL_REFUSALS["change-blocked"].summary),
			"the effective scope blocks its owning setting",
		);
		await session.close();
	});
}
