// The two decisions every media row and the viewer both make, held where they
// are pure: which of the four kinds a media type is, and how a file's size
// reads to a person.
//
// The browser proof drives a picture and a plain file end to end. Video and
// sound differ from those only by this branch — there is no third code path —
// so the branch is pinned here rather than by carrying a video fixture through
// a headless browser to learn the same fact.

import { fileSize, kindOf } from "../web/ui/media.ts";
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
