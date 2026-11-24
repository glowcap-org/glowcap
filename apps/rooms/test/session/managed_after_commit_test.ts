// A press that has sent its change answers the change, never "Nothing was
// sent". The reads and steps that follow a commit fail fast when the link is
// lost and finish over the next link, so the press reports its commit and a
// second press sends nothing twice.
import { assert, assertEquals } from "../assert.ts";
import { settle, until, within } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import {
	type ActionPieces,
	closed,
	FakeClock,
	fakeEnvironment,
	linkedWorkspace,
	oneLinkDoor,
	ownerEntry,
	unread,
} from "../support/managed_link.ts";
import "../support/match_media.ts";
import { ManagedReads } from "../../web/ui/session/managed/reads.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";
import { browserFailure } from "../support/browser_failure.ts";
import { fixture } from "../support/managed_controller.ts";
import { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { fakeHandle } from "../support/managed_link.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { OperationsSession } from "../../web/ui/session/managed/operations.ts";
import { LINK_WAIT_MS } from "../../web/ui/session/managed/link.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";

const DIRECTORY = "ocapn://127.0.0.1%3A1234.tcp";
const ROOM_LINK = "ocapn://127.0.0.1%3A1234.tcp/s/cm9vbQ";

/** A page whose first link commits a room link and then breaks under the
 * read that follows. The next dial waits on `dial`. */
function joined() {
	const accepted = snapshot();
	const first = linkedWorkspace("first", []);
	const second = linkedWorkspace("second", []);
	const dial = deferred<unknown>();
	let submissions = 0;
	let candidate: WorkspaceSnapshot["intent"] | undefined;
	const reads = { first: 0, second: 0 };
	Object.assign(first.workspace, {
		snapshot: () => Promise.resolve(accepted),
		custodyRecipe: () => {
			reads.first++;
			return Promise.reject(closed());
		},
		prepareAcquisition: (_revision: string, _imports: string, _releases: string, intent: string) => {
			candidate = JSON.parse(intent);
			return Promise.resolve({
				submit: () => {
					submissions++;
					assert(candidate != null, "the acquisition was prepared");
					accepted.intent = candidate;
					// The commit is sent and the link ends under what follows it.
					first.lose();
					return Promise.resolve({ status: "committed" });
				},
				free() {},
			});
		},
	});
	Object.assign(second.workspace, {
		snapshot: () => Promise.resolve(accepted),
		custodyRecipe: () => {
			reads.second++;
			return Promise.resolve(ROOM_LINK);
		},
	});
	const clock = new FakeClock();
	const session = viewer(first.workspace, undefined, { relink: () => dial.promise }, false, clock);
	return { session, dial, second, clock, reads, submissions: () => submissions };
}

Deno.test("a room link that committed answers its room when the link is lost under the follow-up read", async () => {
	const f = joined();
	await f.session.start();
	await f.session.readNow();
	const joining = f.session.actions.roomLink(DIRECTORY, ROOM_LINK, "garden", {
		route: "127.0.0.1:1234",
		nick: { kind: "exact", name: "visitor" },
		home: true,
	});
	await settle();
	// The link is away past the bound a first send waits for.
	f.clock.advance(LINK_WAIT_MS + 1);
	await settle();
	f.dial.resolve(f.second.workspace);
	const room = await within(joining, "the commit's answer over the next link");
	assertEquals(typeof room, "string");
	assertEquals(f.submissions(), 1, "the commit is sent once");
	assertEquals(f.reads.second > 0, true, "the follow-up read runs over the next link");
	await f.session.close();
});

const { RoomsPage } = await import("../../web/ui/page.ts");
const { managedOperations } = await import("../../web/ui/session/managed/operations.ts");

/** An operations session whose link is lost for every read that does not
 * wait, and whose waiting reads end as a first send does once the bound
 * passes. */
function lossyOperations(
	held: WorkspaceSnapshot["intent"]["operations"],
	more: Partial<OperationsSession> & Omit<ActionPieces, "actions"> & { lost?: Error } = {},
) {
	const current = snapshot();
	current.intent.operations = held;
	const { lost: given, execute, command, completeResult, readNow, candidateNow, notices, ...rest } = more;
	const lost = given ?? closed();
	const sent: string[] = [];
	const actions = rest.actions ?? {
		operations: unread("operations"),
		replace: unread("replace"),
		run: (name: string) => {
			sent.push(name);
			return Promise.resolve(null);
		},
	};
	const requestNow = rest.requestNow ?? (() => Promise.reject(lost));
	const session: OperationsSession = {
		...oneLinkDoor({}),
		reads: new ManagedReads(),
		current,
		candidateBeforeSending: () => Promise.reject(new LocalRefusal("not-sent")),
		completeOperation: unread("completeOperation"),
		readBeforeSending: () => Promise.reject(new LocalRefusal("not-sent")),
		request: () => Promise.reject(new LocalRefusal("not-sent")),
		requestNow,
		linkTells: (error) => error === lost,
		onRelink: () => () => {},
		subscribe: unread("subscribe"),
		...ownerEntry({
			current,
			requestNow,
			actions: fakeHandle<ManagedRoomsSession["actions"]>(actions),
			execute: execute ?? (async (_id, send, complete) => {
				await complete(await send());
			}),
			command: command ?? (() => Promise.resolve({ id: "op" } as never)),
			completeResult: completeResult ?? (() => Promise.resolve()),
			readNow,
			candidateNow,
			notices,
		}),
		...rest,
		actions,
	};
	return { session, sent, current };
}

Deno.test("an operation that committed answers its commit when the link is lost under the pane reread", async () => {
	const { session, sent } = lossyOperations([{ kind: "listeners", handle: { role: "operations", key: "held" } }]);
	const operations = managedOperations(new RoomsPage(), session);
	assertEquals(await operations.listenerDown(1), "", "the press reports its commit, not a refusal to send");
	assertEquals(sent.length, 1, "the change is sent once");
});

Deno.test("an operation that committed answers its commit, and a pane reread the session refuses is a notice", async () => {
	const refused = browserFailure(-12, "Denied", "access-denied");
	const notices: { source: string; error: unknown }[] = [];
	const { session, sent } = lossyOperations([{ kind: "listeners", handle: { role: "operations", key: "held" } }], {
		requestNow: () => Promise.reject(refused),
		notices,
	});
	const operations = managedOperations(new RoomsPage(), session);
	assertEquals(await operations.listenerDown(1), "", "the press did not fail: the change went through");
	assertEquals(sent.length, 1);
	assertEquals(notices.map((notice) => notice.source), [managedSessionText.changeUnread]);
	assert(notices[0].error === refused, "the notice carries the read's own failure");
});

Deno.test("a gateway connection act that committed retires its selection over the next link", async () => {
	const handle = { role: "operations", key: "connection" };
	const gateway = { role: "operations", key: "gateway" };
	const held = [
		{ kind: "ircGateway", handle: gateway },
		{ kind: "ircConnection", handle, connection: { id: "one", gateway, operation: "made" } },
	];
	let retired: unknown = null;
	let replaces = 0;
	let candidates = 0;
	const lost = closed();
	const state = lossyOperations(held as never, {
		lost,
		readBeforeSending: () => Promise.resolve(snapshot()),
		candidateNow: () => {
			// The first look is under the lost link, the second is over the next.
			if (candidates++ === 0) return Promise.reject(lost);
			const next = snapshot();
			next.intent.operations = held as never;
			return Promise.resolve(next);
		},
		execute: async (_id, send, complete) => {
			const command = await send();
			try {
				await complete(command);
			} catch (error) {
				if (error !== lost) throw error;
				await complete(command);
			}
		},
		command: () => Promise.resolve({ id: "act" } as never),
		completeResult: () => Promise.resolve(),
		linkTells: (error) => error === lost,
		actions: {
			operations: unread("operations"),
			run: unread("run"),
			replace: (next) => {
				replaces++;
				retired = next.intent.operations?.map((row) => row.kind);
				return Promise.resolve();
			},
		},
	});
	const operations = managedOperations(new RoomsPage(), state.session);
	assertEquals(await operations.closeBridgeConnection("one"), "");
	assertEquals(replaces, 1, "the retire is sent once");
	assertEquals(retired, ["ircGateway"]);
});

Deno.test("a directory that committed waits for its registration without a read that waits for the link", async () => {
	const f = fixture();
	const session = f.page.managedSession;
	assert(session != null, "the page shows its session");
	const held = f.current.intent.directories.splice(0);
	let registered = 0;
	session.actions.directory = () => {
		f.current.intent.directories.push(...held);
		return Promise.resolve();
	};
	// The link is away: a read that waits for it ends as a first send does.
	session.readBeforeSending = () => Promise.reject(new LocalRefusal("not-sent"));
	session.directoryRegistered = () => {
		registered++;
		return Promise.resolve();
	};
	try {
		assertEquals(await f.controller.reachDirectory(f.route, { kind: "exact", name: "ada" }), "");
		assertEquals(registered, 1, "the registration is awaited once");
	} finally {
		f.close();
	}
});

Deno.test("a select after a commit lets the link's loss go and the next link sends it once", async () => {
	let up = false;
	const lost = closed();
	const sent: string[] = [];
	const reports: unknown[] = [];
	const navigation = new ManagedNavigation(
		fakeHandle<ManagedRoomsSession>({
			current: snapshot(),
			pending: [],
			linkEnded: (error: unknown) => error === lost,
			completeResult: () => Promise.resolve(),
			execute: async (_id, prepare, complete) => {
				if (!up) throw lost;
				return complete(await prepare(), ownerEntry({}).committed);
			},
			command: (_name: string, args: string[]) => {
				sent.push(args[0]);
				return Promise.resolve({} as never);
			},
		}),
		() => {},
		(error) => reports.push(error),
	);
	await navigation.selectAfterCommit("room");
	assertEquals(navigation.selected, "room", "the choice stays on the page");
	assertEquals(sent, [], "nothing went out on the lost link");
	up = true;
	navigation.relink();
	await until(() => navigation.selected === undefined, "the next link to send the choice");
	assertEquals(sent, ["room"], "the choice goes out once");
	navigation.relink();
	await settle();
	assertEquals(sent, ["room"], "a later link has nothing left to send");
	assertEquals(reports, []);
});

Deno.test("a select after a commit that is refused for another reason still shows its refusal", async () => {
	const refusal = new LocalRefusal("conversation-not-open");
	const navigation = new ManagedNavigation(
		fakeHandle<ManagedRoomsSession>({
			current: snapshot(),
			pending: [],
			linkEnded: () => false,
			execute: () => Promise.reject(refusal),
		}),
	);
	let seen: unknown = null;
	await navigation.selectAfterCommit("room").catch((error) => seen = error);
	assertEquals(seen, refusal);
	assertEquals(navigation.selected, undefined, "a refused choice is dropped");
});

Deno.test("an opening's cleanup that fails once for another reason ends with it and the retry departs once", async () => {
	const denied = new Error("the session refused the read");
	const current = snapshot();
	current.intent.conversations.push({
		kind: "room",
		id: "new",
		directory: "dir",
		name: "new",
		access: "entry",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	let reads = 0;
	const departed: string[] = [];
	const { effects, notices } = fakeEnvironment();
	const session = fakeHandle<ManagedRoomsSession>({
		pending: [],
		effects,
		linkEnded: () => false,
		readBeforeSending: () => reads++ === 0 ? Promise.reject(denied) : Promise.resolve(current),
		...ownerEntry({
			command: (_name: string, args: string[]) => {
				departed.push(args[0]);
				return Promise.resolve({} as never);
			},
			completeResult: () => Promise.resolve(),
		}),
	});
	const opening = new ConversationOpening(session);
	await opening.acquired("new");
	opening.abort();
	await opening.drain().then(() => {
		throw new Error("the cleanup was meant to meet the refused read");
	}, (error) => assertEquals(error, denied));
	assertEquals(departed, []);
	assertEquals(notices.map((notice) => notice.source), [managedSessionText.leaveUnfinished]);
	await opening.acquired("new");
	assertEquals(departed, ["new"], "the departure is sent once");
});
