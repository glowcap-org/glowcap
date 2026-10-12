/**
 * The stage's label sizes, and the two readers that have to agree about them.
 *
 * `stage-labels.ts` is the only place a label's type size, its pill padding
 * and the word an unnamed end wears are written down. These tests are what
 * keeps it the only place: the renderer is checked for a second spelling of a
 * size it should be reading, and the whole source tree is checked for a second
 * spelling of the word. The arithmetic itself is checked where it is used,
 * `keyframe-layout-test/separation.test.ts` for the box a node reserves,
 * `draw-helpers-test/chips.test.ts` for the stagger that keeps two chips apart.
 *
 * They read source text, which is a blunt instrument and deliberate: a
 * duplicated constant compiles perfectly, and there is nothing else at this
 * layer that would notice one.
 */

import { assert, assertEquals } from "@std/assert";
import {
	EDGE_CHIP_LABEL,
	endpointLabelText,
	lineBoxPx,
	MESSAGE_LABEL,
	NODE_LABEL,
	peerLabelText,
	pillSize,
} from "./stage-labels.ts";
import { UNNAMED_END_LABEL } from "../schema/session-end.ts";
import { IDENTIFIER_ELIDE_ABOVE } from "../ui/elide.ts";

async function sourceOf(path: string): Promise<string> {
	return await Deno.readTextFile(new URL(path, import.meta.url));
}

/** Every `.ts` / `.tsx` file under `src/`, with its path relative to `src/`. */
async function sourceFiles(): Promise<Array<{ path: string; text: string }>> {
	const root = new URL("../", import.meta.url);
	const out: Array<{ path: string; text: string }> = [];
	const walk = async (dir: URL, prefix: string): Promise<void> => {
		for await (const entry of Deno.readDir(dir)) {
			const at = new URL(
				`${entry.name}${entry.isDirectory ? "/" : ""}`,
				dir,
			);
			if (entry.isDirectory) {
				await walk(at, `${prefix}${entry.name}/`);
			} else if (
				entry.name.endsWith(".ts") || entry.name.endsWith(".tsx")
			) {
				out.push({
					path: `${prefix}${entry.name}`,
					text: await Deno.readTextFile(at),
				});
			}
		}
	};
	await walk(root, "");
	return out;
}

async function rendererSource(): Promise<string> {
	const parts = [await sourceOf("./render-frame.ts")];
	for await (
		const entry of Deno.readDir(new URL("./sprites/", import.meta.url))
	) {
		if (entry.name.endsWith(".ts")) {
			parts.push(await sourceOf(`./sprites/${entry.name}`));
		}
	}
	return parts.join("\n");
}

Deno.test("the renderer sets every stage label from the shared metrics", async () => {
	// The drift this whole module exists to stop: the renderer spelling a font
	// size or a pill padding itself, while the layout goes on reserving room
	// for a stale size. Both stay green. One draws bigger labels and
	// the other separates the smaller boxes, and the labels overlap on screen.
	const source = await rendererSource();
	assertEquals(
		source.match(/fontSize:\s*\d/g),
		null,
		"the renderer sets a font size from a number of its own rather than from stage-labels.ts",
	);
	const calls = [...source.matchAll(/layoutPillBackground\(([\s\S]*?)\);/g)];
	assert(calls.length > 0, "no pill is drawn at all");
	for (const call of calls) {
		assert(
			/NODE_LABEL|EDGE_CHIP_LABEL|MESSAGE_LABEL/.test(call[1]!),
			`a pill is drawn with padding of its own: ${call[1]!.trim()}`,
		);
	}
});

Deno.test("the word for an end that claims nothing has one spelling", async () => {
	// It is arithmetic as well as prose: the layout reserves room for this
	// phrase before the renderer writes it, so a second spelling one character
	// longer is a label wider than the box kept clear for it.
	const owner = "schema/session-end.ts";
	for (const file of await sourceFiles()) {
		if (file.path === owner || /\.test\.tsx?$/.test(file.path)) continue;
		assert(
			!file.text.includes(`"${UNNAMED_END_LABEL}"`),
			`${file.path} spells "${UNNAMED_END_LABEL}" itself instead of reading UNNAMED_END_LABEL from ${owner}`,
		);
	}
});

Deno.test("a pill is measured from the size its text is set in", () => {
	// Padding lands on both sides, and a longer string in a wider family takes
	// more room. Small claims, but they are what `nodeFootprint` and the edge
	// stagger both rest on.
	const empty = pillSize(0, NODE_LABEL, false);
	assertEquals(empty.width, NODE_LABEL.padX * 2);
	assertEquals(
		empty.height,
		lineBoxPx(NODE_LABEL.fontPx) + NODE_LABEL.padY * 2,
	);
	assert(
		pillSize(10, NODE_LABEL, true).width >
			pillSize(10, NODE_LABEL, false).width,
	);
	assert(
		pillSize(20, EDGE_CHIP_LABEL, true).width >
			pillSize(10, EDGE_CHIP_LABEL, true).width,
	);
	// The two chip captions differ in type size and in nothing else.
	assertEquals(MESSAGE_LABEL.padX, EDGE_CHIP_LABEL.padX);
	assertEquals(MESSAGE_LABEL.padY, EDGE_CHIP_LABEL.padY);
});

Deno.test("a long designator is shortened before it is drawn", () => {
	// A sixty-four character host id drew a pill several times wider than the
	// graph it belonged to, which is why a hub's ends could not fan onto one
	// ring. The stage shortens it the way every other surface does.
	const hostId = "9f".repeat(32);
	const drawn = endpointLabelText(hostId);
	assert(drawn.length < hostId.length, "the designator was drawn whole");
	assert(drawn.length <= IDENTIFIER_ELIDE_ABOVE + 1);
	// Short ones are left alone: eliding them would lose the middle and gain no
	// room.
	assertEquals(endpointLabelText("tcp://a:1"), "tcp://a:1");
	assertEquals(endpointLabelText(undefined), UNNAMED_END_LABEL);
});

Deno.test("a long peer caption is shortened before it is drawn", () => {
	// A peer with no stated name wears its id, and a wire-derived id runs as
	// long as a designator does. Drawn whole it is the same pill several times
	// wider than the graph, so it takes the same shortening.
	const peerId = `glowcap-${"7c".repeat(30)}`;
	const drawn = peerLabelText(peerId);
	assert(drawn.length < peerId.length, "the peer caption was drawn whole");
	assert(drawn.length <= IDENTIFIER_ELIDE_ABOVE + 1);
	// The middle is what goes, so both ends survive: two peers whose ids share
	// a prefix still draw as two different nodes.
	const sibling = peerLabelText(`glowcap-${"7c".repeat(29)}9a9a`);
	assert(
		drawn !== sibling,
		"two ids sharing a long prefix drew the same caption",
	);
	// A name a person chose is normally well under the threshold and is left
	// exactly as written.
	assertEquals(peerLabelText("Carol (exporter)"), "Carol (exporter)");
});

Deno.test("no stage caption is set straight from an entity field", async () => {
	// The drift that put this here: the renderer drew `e.peer.label` whole
	// while the layout reserved room for whatever `peerLabelText` returns, so
	// a long caption ran across its neighbors AND the solver held daylight
	// clear for a string nobody drew. Every `Text` the stage builds takes its
	// string from a named function in `stage-labels.ts`, which is the same
	// function the layout measures.
	const source = await rendererSource();
	const straight = [...source.matchAll(/text:\s*(e\.[\w.]+)/g)];
	assertEquals(
		straight.map((m) => m[1]),
		[],
		"a stage label is set from an entity field the layout cannot have measured",
	);
});
