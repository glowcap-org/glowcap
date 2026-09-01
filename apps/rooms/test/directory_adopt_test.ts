// A hosted Share reuses live directory sessions instead of redialing them.

import {
	adoptDirectories,
	type AdoptedDirectory,
	adoptedRegistrationNick,
	takeAdoptedDirectory,
} from "../session/directory_adopt.ts";
import type { Directory } from "../lib/room/client.ts";
import { roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { assertEquals } from "./assert.ts";

function held(directory: Directory, nick: string, id = "home"): Map<string, AdoptedDirectory> {
	return new Map([[id, { directory, nick }]]);
}

Deno.test("an adopted directory is taken once by id", () => {
	const first = { id: "first" } as unknown as Directory;
	const pending = held(first, "ada");
	adoptDirectories(pending);
	const taken = takeAdoptedDirectory("home");
	assertEquals(taken?.directory, first);
	assertEquals(taken?.nick, "ada");
	assertEquals(takeAdoptedDirectory("home"), undefined);
	assertEquals(pending.has("home"), false);
});

Deno.test("an adopted directory is taken by locator authority when the id spelling differs", () => {
	const first = { id: "first" } as unknown as Directory;
	const authority = roomsPeerAuthority(roomsLocator("127.0.0.1:9"));
	const pending = new Map<string, AdoptedDirectory>([[authority, { directory: first, nick: "ada2" }]]);
	adoptDirectories(pending);
	const taken = takeAdoptedDirectory("other-id", "127.0.0.1:9");
	assertEquals(taken?.directory, first);
	assertEquals(taken?.nick, "ada2");
	assertEquals(pending.size, 0);
});

Deno.test("hosted re-register uses the stolen grant, not the checkpoint request", () => {
	const directory = { id: "dir" } as unknown as Directory;
	assertEquals(adoptedRegistrationNick("ada", { directory, nick: "ada2" }), "ada2");
	assertEquals(adoptedRegistrationNick("ada", { directory, nick: "" }), "ada");
	assertEquals(adoptedRegistrationNick("ada", undefined), "ada");
});
