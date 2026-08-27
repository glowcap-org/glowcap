// The two decisions every media row and the viewer both make, held where they
// are pure: which of the four kinds a media type is, and how a file's size
// reads to a person.
//
// The browser proof drives a picture and a plain file end to end. Video and
// sound differ from those only by this branch — there is no third code path —
// so the branch is pinned here rather than by carrying a video fixture through
// a headless browser to learn the same fact.

import { fetchesOnArrival, fileSize, kindOf } from "../web/ui/media.ts";
import { attachmentRefusal, readAttachmentsExact } from "../lib/attachment.ts";
import { AUTO_IMAGE_BYTES, MAX_ATTACHMENT_BYTES, MAX_MESSAGE_FILES } from "../lib/limits.ts";
import { Ref } from "@pancake/runtime";
import { assertEquals } from "./assert.ts";

Deno.test("a media type picks how the file is met", () => {
	assertEquals(kindOf("image/png"), "image");
	assertEquals(kindOf("image/svg+xml"), "image");
	assertEquals(kindOf("video/mp4"), "video");
	assertEquals(kindOf("audio/ogg"), "audio");
	// Anything else is a file to download, including an empty type, which is
	// what a browser gives for a file it does not recognise.
	assertEquals(kindOf("application/pdf"), "file");
	assertEquals(kindOf(""), "file");
	// The prefix has to be the type's own, not a substring of it: a name-like
	// type that merely mentions one is not that kind.
	assertEquals(kindOf("application/vnd.image-thing"), "file");
});

Deno.test("a size reads the way the reader is deciding about it", () => {
	assertEquals(fileSize(0), "0 B");
	assertEquals(fileSize(1023), "1023 B");
	assertEquals(fileSize(1024), "1.0 kB");
	assertEquals(fileSize(1536), "1.5 kB");
	assertEquals(fileSize(1024 * 1024), "1.0 MB");
	assertEquals(fileSize(1468006), "1.4 MB");
});

Deno.test("a file a room will not take is refused in words that name it", () => {
	// The sender checks so nothing moves, and the room checks because it cannot
	// trust a sender. Two checks, one answer: they were written out twice, word
	// for word, and two authorities for one rule drift the moment either moves.
	assertEquals(attachmentRefusal("notes.txt", "text/plain", 12), null);
	assertEquals(attachmentRefusal("", "text/plain", 12), "a file needs a name");

	// Named, because a message may carry several and a rule stated in the
	// abstract leaves a reader looking at eight chips with nothing to act on.
	const big = attachmentRefusal("holiday.mov", "video/quicktime", MAX_ATTACHMENT_BYTES + 1);
	assertEquals(big !== null && big.includes("holiday.mov"), true, `the refusal did not name the file: ${big}`);
	assertEquals(big !== null && big.includes("MB"), true, `the refusal spoke in bytes: ${big}`);

	// A size that is not a size at all, which is what a peer can put on the wire.
	assertEquals(attachmentRefusal("x.bin", "application/octet-stream", -1) !== null, true);
	assertEquals(attachmentRefusal("x.bin", "application/octet-stream", Number.NaN) !== null, true);

	// A name too long to show is cut for the message rather than repeated whole.
	const long = attachmentRefusal("y".repeat(500) + ".txt", "text/plain", 1);
	assertEquals(long !== null && long.includes("504"), true, `the refusal did not say how long it was: ${long}`);
});

Deno.test("a small picture is fetched on arrival; other files wait to be asked", () => {
	const picture = { mime: "image/png", size: 1024 };
	assertEquals(fetchesOnArrival(picture, false), true);
	// Anything that is not a picture has a control of its own, and a picture too
	// large to spend a reader's bandwidth on unasked has one too.
	assertEquals(fetchesOnArrival({ mime: "application/pdf", size: 1024 }, false), false);
	assertEquals(fetchesOnArrival({ mime: "video/mp4", size: 1024 }, false), false);
	assertEquals(fetchesOnArrival({ mime: "image/png", size: AUTO_IMAGE_BYTES + 1 }, false), false);
});

Deno.test("nothing is fetched on its own from a member the reader has silenced", () => {
	// Silence has to reach the network, not just the drawing: a line the reader
	// will not see must not pull bytes about itself either, and for a direct
	// message that pull would reach the silenced person's own host. The reference
	// is still kept, so unignoring and pressing the file works.
	assertEquals(fetchesOnArrival({ mime: "image/png", size: 1024 }, true), false);
});

Deno.test("mutation attachment parsing refuses incomplete and over-cap suffixes", () => {
	const blob = Object.create(Ref.prototype) as Ref;
	assertEquals(
		(() => {
			try {
				readAttachmentsExact([
					"operation",
					0n,
					"room",
					"caption",
					"file",
					"notes.txt",
					"text/plain",
					1n,
					blob,
					0n,
					0n,
					"trailing",
				]);
				return false;
			} catch {
				return true;
			}
		})(),
		true,
	);
	assertEquals(
		(() => {
			try {
				readAttachmentsExact([
					"operation",
					0n,
					"room",
					"caption",
					...Array.from({ length: (MAX_MESSAGE_FILES + 1) * 7 }, () => "file"),
				]);
				return false;
			} catch {
				return true;
			}
		})(),
		true,
	);
});
