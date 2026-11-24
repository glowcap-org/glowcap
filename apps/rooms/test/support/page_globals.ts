// The page globals a committed move reads: its location, history and document,
// with the number of reloads it asked for.

/** Run `run` with those globals faked, and restore them after. */
export async function withPageGlobals(run: (reloads: () => number) => Promise<void>): Promise<void> {
	const prior = {
		location: Object.getOwnPropertyDescriptor(globalThis, "location"),
		history: Object.getOwnPropertyDescriptor(globalThis, "history"),
		document: Object.getOwnPropertyDescriptor(globalThis, "document"),
	};
	let reloads = 0;
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { pathname: "/", href: "https://rooms.test/", reload: () => reloads++ },
	});
	Object.defineProperty(globalThis, "history", { configurable: true, value: { replaceState() {} } });
	// A page a Rooms server sent: it carries no host mark, so it reloads in place.
	Object.defineProperty(globalThis, "document", {
		configurable: true,
		value: { baseURI: "https://rooms.test/", querySelector: () => null },
	});
	try {
		await run(() => reloads);
	} finally {
		for (const [name, descriptor] of Object.entries(prior)) {
			if (descriptor != null) Object.defineProperty(globalThis, name, descriptor);
			else Reflect.deleteProperty(globalThis, name);
		}
	}
}
