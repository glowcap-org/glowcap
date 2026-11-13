// What a change to the page moves: where each row of a changed log starts
// from, and which rows of a roster are arrivals.
import { planTravel, type TravelRow } from "../web/ui/panes/log_travel.tsx";
import { arrivals } from "../web/ui/conversation.ts";
import { assertEquals } from "./assert.ts";

const SCREEN = 600;
const PLACED = { covered: 0, until: 1 };

function row(was: [number, number] | null, now: [number, number], more: Partial<TravelRow> = {}): TravelRow {
	return {
		was: was == null ? null : { top: was[0], bottom: was[1] },
		now: { top: now[0], bottom: now[1] },
		reflows: false,
		underway: 0,
		...more,
	};
}

Deno.test("a line that lands rises with the rows it pushed up", () => {
	const starts = planTravel(
		[row([400, 440], [360, 400]), row([440, 480], [400, 440]), row(null, [440, 480])],
		SCREEN,
		600,
	);
	assertEquals(starts, [{ by: 40, ...PLACED }, { by: 40, ...PLACED }, { by: 40, ...PLACED }]);
});

Deno.test("a line that lands on rows still moving starts as far off as they are drawn", () => {
	const starts = planTravel([row([400, 440], [360, 400], { underway: 25 }), row(null, [400, 440])], SCREEN, 600);
	assertEquals(starts, [{ by: 40, ...PLACED }, { by: 65, ...PLACED }]);
});

Deno.test("a line taller than the room under the log is covered by the row leaving its place", () => {
	// The row above starts 200 lower, where it stood. The line may start 60
	// lower, so 140 of its top is under that row.
	const starts = planTravel([row([300, 440], [100, 240]), row(null, [240, 440])], SCREEN, 500);
	assertEquals(starts, [{ by: 200, ...PLACED }, { by: 60, covered: 140, until: 1 }]);
});

Deno.test("a line with no room under the log is let out where it stands", () => {
	const starts = planTravel([row([400, 440], [360, 400]), row(null, [400, 440])], SCREEN, 440);
	assertEquals(starts[1], { by: 0, covered: 40, until: 1 });
});

Deno.test("lines that land together move together, and each is let out as the row above passes it", () => {
	// The card moved up 150 and the lines may start 100 lower, so the card's
	// edge starts 50 into them: over all of the first 36, and 10 of the second.
	const starts = planTravel(
		[
			row([456, 540], [306, 390], { reflows: true }),
			row(null, [394, 430]),
			row(null, [434, 470]),
			row(null, [474, 540]),
		],
		SCREEN,
		640,
	);
	assertEquals(starts, [
		{ by: 150, ...PLACED },
		{ by: 100, covered: 50, until: 1 },
		{ by: 100, covered: 10, until: 0.2 },
		{ by: 100, ...PLACED },
	]);
});

Deno.test("a row that lands between two that stood moves as the one after it", () => {
	// The card above moved up to make room and the line below did not move, so
	// the new row stands still and the card uncovers it.
	const starts = planTravel(
		[row([300, 400], [240, 340], { reflows: true }), row(null, [344, 400]), row([404, 440], [404, 440])],
		SCREEN,
		600,
	);
	assertEquals(starts, [{ by: 60, ...PLACED }, { by: 0, covered: 60, until: 1 }, { by: 0, ...PLACED }]);
});

Deno.test("a row that lands above rows pushed down comes out from under the row before it", () => {
	const starts = planTravel(
		[row([100, 140], [100, 140]), row(null, [144, 200]), row([144, 184], [204, 244])],
		SCREEN,
		600,
	);
	assertEquals(starts, [{ by: 0, ...PLACED }, { by: -60, covered: 60, until: 1 }, { by: -60, ...PLACED }]);
});

Deno.test("a row that grew at its end starts where it stood", () => {
	const starts = planTravel([row([400, 440], [200, 440])], SCREEN, 500);
	assertEquals(starts, [{ by: 200, ...PLACED }]);
});

Deno.test("a log that cuts off what passes its end lets a line rise all the way", () => {
	const starts = planTravel([row([300, 440], [100, 240]), row(null, [240, 440])], SCREEN, Infinity);
	assertEquals(starts, [{ by: 200, ...PLACED }, { by: 200, ...PLACED }]);
});

Deno.test("rows close up where one was taken away", () => {
	const starts = planTravel([row([100, 140], [100, 140]), row([184, 224], [144, 184])], SCREEN, 600);
	assertEquals(starts, [{ by: 0, ...PLACED }, { by: 40, ...PLACED }]);
});

Deno.test("a row that changes size where it stands travels by its end", () => {
	const starts = planTravel([row([300, 400], [180, 380], { reflows: true })], SCREEN, 600);
	assertEquals(starts, [{ by: 20, ...PLACED }]);
});

Deno.test("a row moved farther than a screen is drawn where it is, and carries nothing", () => {
	const starts = planTravel([row([100, 140], [900, 940]), row(null, [940, 980])], SCREEN, 1200);
	assertEquals(starts, [{ by: 0, ...PLACED }, { by: 0, ...PLACED }]);
});

Deno.test("a log that opens with rows nobody saw before leaves them where they are", () => {
	const starts = planTravel([row(null, [100, 140]), row(null, [140, 180])], SCREEN, 600);
	assertEquals(starts, [{ by: 0, ...PLACED }, { by: 0, ...PLACED }]);
});

Deno.test("a roster is filled in once, and after that whoever arrives rises", () => {
	const nobody = { key: "room", names: new Set<string>() };
	const two = { key: "room", names: new Set(["ada", "bo"]) };
	assertEquals(arrivals({ key: "other", names: new Set(["ada"]) }, "room", ["ada", "bo"]), [], "a room just opened");
	assertEquals(arrivals(nobody, "room", []), [], "a room that has not said who is in it");
	assertEquals(arrivals(nobody, "room", ["ada", "bo"]), "all", "a room saying who is in it");
	assertEquals(arrivals(two, "room", ["ada", "bo", "cy"]), [2], "somebody arriving");
	assertEquals(arrivals(two, "room", ["bo"]), [], "somebody leaving");
	assertEquals(arrivals(two, null, []), [], "no room");
});
