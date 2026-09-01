// Media in a room: uploading it, holding it, reading it, and letting it go.
//
// A room hosts the bytes rather than relaying a reference to whoever posted
// them, so these are the tests of what that costs the room — the ceilings, the
// reservations, the eviction — and of what a member sees when a file is no
// longer there.

import "./files/post.ts";
import "./files/dm.ts";
import "./files/limits.ts";
