// A rooms chat client, written on pancake actors in native Deno.
//
// It connects, fetches the room by name, publishes a local `inbox` actor, and
// hands the room a capability to that inbox when it subscribes. From then on the
// room calls the client back — the client never polls. It waits until everyone
// it expects is in the room, posts one line, and collects each expected member's
// line as the room pushes it back.
//
//   deno run --allow-ffi --allow-net client.ts 127.0.0.1:9099 alice "hi" alice,bob,carol
//
// The first argument is the locator: a `host:port` joins over TCP, an
// `ocapn://<nodeid>.iroh?…` URI joins over iroh.
//
// The last argument is the roster: a comma-separated list of the member nicks to
// expect (default: just you). The client posts only once every roster member is
// present, so an all-to-all broadcast is deterministic no matter what order the
// members connect in — it learns who is present from its welcome (which names
// everyone already in the room) and from the room's join announcements. It exits
// 0 once it has seen a line from every roster member, and 1 on timeout. Members
// outside the roster (people already chatting in an attached room, say) are
// printed but never counted, so a busy room cannot fake or break the assertion.

import { dial } from "./locator.ts";
import { NOTIFY, POST, ROOM, SUBSCRIBE } from "./protocol.ts";

/** The welcome ends with the nicks already present: `… in the room: a, b, c`. */
function welcomeNames(text: string): string[] {
  const m = text.match(/ in the room: (.+)$/);
  return m ? m[1].split(", ") : [];
}

/** The room announces each arrival as `<nick> joined (<count> here)`. */
function joinedNick(text: string): string | null {
  const m = text.match(/^(.+) joined \(\d+ here\)$/);
  return m ? m[1] : null;
}

/** Run one client session: subscribe, wait for every roster member to be
 * present, post `line`, and collect the chat line each roster member sends.
 * Resolves with the transcript of real chat lines (join announcements
 * excluded). */
export async function runClient(
  locator: string,
  nick: string,
  line: string,
  roster: string[] = [nick],
  timeoutMs = 10000,
): Promise<string[]> {
  const conn = await dial(locator);
  conn.serve().catch(() => {});

  const chatLines: string[] = [];
  const present = new Set<string>();
  const seen = new Set<string>();
  let posted = false;
  let finish!: () => void;
  const done = new Promise<void>((resolve) => {
    finish = resolve;
  });

  const room = await conn.fetch(ROOM);

  function maybePost(): void {
    if (!posted && roster.every((n) => present.has(n))) {
      posted = true;
      conn.send(room, POST, [line]).catch(() => {});
    }
  }

  // The inbox the room calls back on: a `notify(from, text)` is either a room
  // announcement (from "room") or a chat line from a member.
  const inbox = conn.spawn((verb, args) => {
    if (verb !== NOTIFY) throw new Error(`inbox has no method ${verb}`);
    const from = typeof args[0] === "string" ? args[0] : "?";
    const text = typeof args[1] === "string" ? args[1] : "";
    console.log(`[${nick}] ${from}: ${text}`);
    if (from === "room") {
      const joined = joinedNick(text);
      if (joined !== null) present.add(joined);
    } else {
      present.add(from); // a line is presence too
      chatLines.push(`${from}: ${text}`);
      if (roster.includes(from)) {
        seen.add(from);
        if (seen.size >= roster.length) finish();
      }
    }
    maybePost();
    return null;
  });

  // Subscribe, handing the room a capability to our inbox. The welcome names
  // everyone already present — the only way to learn about earlier arrivals.
  const welcome = await conn.send(room, SUBSCRIBE, [nick, inbox]);
  for (const n of welcomeNames(typeof welcome === "string" ? welcome : "")) present.add(n);
  maybePost();

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((_, reject) => {
    timer = setTimeout(() => reject(new Error("timeout")), timeoutMs);
  });
  try {
    await Promise.race([done, timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    conn.close();
  }

  if (seen.size < roster.length) {
    const missing = roster.filter((n) => !seen.has(n)).join(", ");
    throw new Error(`${nick} saw lines from ${seen.size}/${roster.length} members before timeout (missing: ${missing})`);
  }
  return chatLines;
}

if (import.meta.main) {
  const [locator, nick, line, rosterStr] = Deno.args;
  if (!locator || !nick || line === undefined) {
    console.error("usage: client.ts <locator> <nick> <line> [roster]   (locator: host:port or an ocapn://…iroh URI; roster: comma-separated nicks to expect; default just you)");
    Deno.exit(2);
  }
  try {
    await runClient(locator, nick, line, rosterStr ? rosterStr.split(",") : [nick]);
    Deno.exit(0);
  } catch (err) {
    console.error(`client ${nick} failed: ${err instanceof Error ? err.message : err}`);
    Deno.exit(1);
  }
}
