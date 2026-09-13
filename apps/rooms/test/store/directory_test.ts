// Directory presentation treats home identity, locator spelling, naming, and color as one coherent destination.
import "../support/browser_application.ts";
// How this page names and colors directories, and how a locator field treats
// this directory as the empty destination rather than a second address.

const types = await import("../../web/ui/types.ts");
const text = await import("../../web/ui/text.ts");
const joining = await import("../../web/ui/joining.ts");
const { dirId } = types;

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("empty and this directory's locator are one destination", () => {
	const home = dirId("ocapn://abc.iroh");
	const context = { home, defaultDirectory: { id: home, locator: home } };
	assert(joining.thisDirectoryLocator("", context) === "", "an empty locator was not this directory");
	assert(
		joining.thisDirectoryLocator("ocapn://abc.iroh", context, home) === "",
		"this directory's locator was kept as a distinct value",
	);
	assert(
		joining.thisDirectoryLocator(" ocapn://abc.iroh\n", context, home) === "",
		"a pasted home locator was not cleared",
	);
	assert(
		joining.thisDirectoryLocator("ocapn://other.iroh", context) === "ocapn://other.iroh",
		"a foreign locator was treated as this directory",
	);
	const roomLink = "ocapn://abc.iroh/s/room-swiss";
	assert(
		joining.thisDirectoryLocator(roomLink, context, home) === roomLink,
		"a room link on this directory was collapsed to the directory default",
	);
});

Deno.test("an empty locator field hints at this directory's shared address", () => {
	// The placeholder shortens the same route every share surface hands out
	// (`peer.dirAddress`), so the hint agrees with the Settings and directory
	// cards rather than showing the store's bare authority key.
	assert(
		joining.joinLocatorPlaceholder(null) === joining.JOIN_LOCATOR_SHAPE,
		"a page with no home invented an address",
	);
	assert(
		joining.joinLocatorPlaceholder("ocapn://abc.iroh") === "ocapn://abc.iroh",
		"a short locator was shortened",
	);
	assert(
		joining.joinLocatorPlaceholder(
			"ocapn://abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqr.iroh",
		) === "ocapn://abcd…mnopqr.iroh",
		"a long locator was not shown as head, tail, and transport",
	);
	assert(
		joining.joinLocatorPlaceholder(
			"ocapn://abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqr.iroh?direct-addresses=127.0.0.1:1",
		) === "ocapn://abcd…mnopqr.iroh",
		"the shared hinted route kept its query parameters in the hint",
	);
	assert(
		joining.joinLocatorPlaceholder("127.0.0.1:8000") === "127.0.0.1:8000",
		"a host locator was rewritten as an ocapn URI",
	);
	assert(
		joining.joinLocatorPlaceholder("ocapn://127.0.0.1%3A8000.tcp") === "127.0.0.1:8000",
		"a native TCP URI hid its host and port behind abbreviation",
	);
});

Deno.test("this directory wears one mark across the page", () => {
	const home = dirId("ocapn://abc.iroh");
	const other = dirId("ocapn://other.iroh");
	assert(types.dirMark(home, home, 1) === "home", "this directory wore a ramp slot");
	assert(types.dirMark(other, home, 2) === "2", "a foreign directory did not wear its slot");
	assert(types.dirMark(home, null, 1) === "1", "with no home, a directory was treated as this page's");
});

Deno.test("a directory is named in words however many are held, and colored only within the ramp", () => {
	const home = dirId("ocapn://home.iroh");
	const held = (count: number) =>
		new Map(
			Array.from({ length: count }, (_, i) => {
				const id = i === 0 ? home : dirId(`ocapn://dir-${i}.iroh`);
				return [id, { id, slot: i + 1 }];
			}),
		) as unknown as ReadonlyMap<
			import("../../web/ui/types.ts").DirId,
			import("../../web/ui/types.ts").DirView
		>;

	const alone = held(1);
	assert(!types.dirsAreNamed(alone), "one directory was named on every row, where there is nothing to tell apart");
	assert(!types.dirsWearMarks(alone), "one directory wore a color to be told apart from itself");

	for (const count of [2, 3, 4, 5]) {
		assert(types.dirsAreNamed(held(count)), `${count} directories said nothing about which is which`);
		assert(types.dirsWearMarks(held(count)), `${count} directories wore no color, inside the ramp`);
	}

	const crowded = held(6);
	assert(types.dirsAreNamed(crowded), "six directories took the words off the rows that needed them most");
	assert(!types.dirsWearMarks(crowded), "six directories wore five colors and a gap");

	// And the two answers arrive as one value, so a row cannot be handed a color
	// with no words behind it. That is the whole rule stated as a type: a mark is
	// reachable only through a name.
	const far = dirId("ocapn://dir-1.iroh");
	const inRamp = text.dirWhere(far, home, held(3));
	assert(inRamp.name === "dir-1" && inRamp.mark === "2", `a row inside the ramp read ${JSON.stringify(inRamp)}`);
	const pastRamp = text.dirWhere(far, home, crowded);
	assert(pastRamp.name === "dir-1", "past the ramp a row stopped saying which directory it is on");
	assert(pastRamp.mark === undefined, `past the ramp a row wore ${JSON.stringify(pastRamp.mark)}`);
	const only = text.dirWhere(home, home, alone);
	assert(only.name === null && only.mark === undefined, `one directory drew ${JSON.stringify(only)} on every row`);

	// Whatever this tab holds, a color never arrives without the words that say
	// the same thing, which is the invariant the rail rows are drawn from.
	for (const count of [1, 2, 5, 6, 9]) {
		const dirs = held(count);
		for (const id of dirs.keys()) {
			const where = text.dirWhere(id, home, dirs);
			assert(
				where.mark === undefined || where.name !== null,
				`with ${count} held, a row wore ${JSON.stringify(where.mark)} and named no directory`,
			);
		}
	}
});
