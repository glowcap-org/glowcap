/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const memory = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: (key: string) => memory.get(key) ?? null,
		setItem: (key: string, value: string) => memory.set(key, value),
		removeItem: (key: string) => memory.delete(key),
		key: (at: number) => [...memory.keys()][at] ?? null,
		get length() {
			return memory.size;
		},
	},
});

const {
	emptyRoomsSessionState,
	redactWorkspaceCapabilities,
} = await import("../lib/rooms_state.ts");
const store = await import("../web/ui/store.ts");
const workspace = await import("../web/ui/workspace_state.ts");
const { dirId } = await import("../web/ui/types.ts");
const { assertEquals } = await import("./assert.ts");

const source = "ocapn://source.id";
const destination = "ocapn://destination.id";
const intent = { id: "publication-1", destination, source: "room-1", name: "annex" };

function documentWithIntent() {
	const session = emptyRoomsSessionState();
	return {
		version: workspace.WORKSPACE_STATE_VERSION,
		controller: { kind: "local" as const },
		session: {
			...session,
			directories: [
				{ id: source, locator: source, home: true, nick: "ada", standing: null },
				{ id: destination, locator: destination, home: false, nick: "ada", standing: null },
			],
			conversations: [{
				kind: "room" as const,
				id: "room-1",
				directory: source,
				name: "source-room",
				held: false,
				standing: null,
				draft: "",
			}],
			capabilities: {
				operations: [{ capability: "peering" as const, scope: destination, swiss: "peering-swiss" }],
				archivePeer: null,
			},
			peering: [],
		},
		view: {
			theme: "light" as const,
			notifyOn: false,
			railOpen: true,
			rosterOpen: true,
			settingsTab: "overview" as const,
			opsPane: "peering" as const,
		},
	};
}

Deno.test("local peering intent survives refresh before a lease exists", () => {
	const document = documentWithIntent();
	memory.set(workspace.WORKSPACE_STATE_KEY, JSON.stringify(document));
	const restored = workspace.restoreWorkspaceState((locator) => dirId(locator));
	assertEquals(restored.foreignLocators, [destination]);
	assertEquals(workspace.addWorkspacePeeringIntent(intent), true);
	assertEquals(workspace.workspacePeeringIntents(), [intent]);
	assertEquals(workspace.workspaceStateOf(store.get()).session.peering, [intent]);
});

Deno.test("local peering revoke removes the intent and redaction removes publication authority", () => {
	assertEquals(workspace.removeWorkspacePeeringIntent(intent.id), true);
	assertEquals(workspace.workspacePeeringIntents(), []);
	assertEquals(workspace.workspaceStateOf(store.get()).session.peering, []);
	const redacted = redactWorkspaceCapabilities(workspace.workspaceStateOf(store.get()));
	assertEquals(redacted.session.peering, []);
	memory.delete(workspace.WORKSPACE_STATE_KEY);
});
