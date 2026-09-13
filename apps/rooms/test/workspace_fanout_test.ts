// Workspace document bounds: reconnect fan-out and duplicate bearer authority.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { parseWorkspaceState } = await import("../web/ui/workspace_state.ts");
const { registrationId } = await import("./support/registration.ts");
const { workspaceFixture: valid } = await import("./support/workspace.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("workspace state bounds reconnect and credential fan-out", () => {
	const directoryBase = valid();
	const manyDirectories = {
		...directoryBase,
		session: {
			...directoryBase.session,
			directories: Array.from({ length: 33 }, (_, at) => ({
				id: `ocapn://directory-${at}.iroh`,
				locator: `ocapn://directory-${at}.iroh`,
				home: at === 0,
				nick: "ada",
				standing: null,
			})),
			conversations: [],
			active: null,
		},
	};
	assert(
		parseWorkspaceState(JSON.stringify(manyDirectories)) === null,
		"too many directory reconnects were accepted",
	);

	const conversationBase = valid();
	const manyConversations = {
		...conversationBase,
		session: {
			...conversationBase.session,
			conversations: Array.from({ length: 257 }, (_, at) => ({
				kind: "direct",
				id: `dm-${at}`,
				directory: "ocapn://directory.iroh",
				peer: `peer-${at}`,
				peerRegistrationId: registrationId(at),
				closed: false,
				draft: at === 0 ? "x".repeat(70_000) : "",
			})),
			active: null,
		},
	};
	assert(
		parseWorkspaceState(JSON.stringify(manyConversations)) === null,
		"too many conversation replays were accepted",
	);
	const duplicateCredential = valid();
	duplicateCredential.session.capabilities.operations.push({
		...duplicateCredential.session.capabilities.operations[0],
	});
	assert(
		parseWorkspaceState(JSON.stringify(duplicateCredential)) === null,
		"duplicate bearer authority was accepted",
	);
	const duplicateVisualizer = valid();
	duplicateVisualizer.session.capabilities.operations.push({
		capability: "trace",
		scope: "wss://elsewhere.test/trace",
		swiss: "another-trace-swiss",
	});
	assert(
		parseWorkspaceState(JSON.stringify(duplicateVisualizer)) === null,
		"multiple app-wide visualizer capabilities were accepted",
	);
});
