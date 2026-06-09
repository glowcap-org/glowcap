// A rooms chat client, written on pancake actors in native Deno.
//
// It connects, fetches the room by name, publishes a local `inbox` actor, and
// hands the room a capability to that inbox when it subscribes. From then on the
// room calls the client back — the client never polls. It waits until the room is
// full (it learns the head count from the room's own join announcements), posts
// one line, and collects every member's line as the room pushes it back.
//
//   deno run --allow-ffi --allow-net client.ts 127.0.0.1 9099 alice "hi" 3
//
// The last argument is how many members to expect; the client posts only once
// that many have joined, so an all-to-all broadcast is deterministic no matter
// what order the members connect in. It exits 0 once it has seen a line from
// every member, and 1 on timeout.

import { connect } from "../../../../bindings/deno/pancake.ts";
import { NOTIFY, POST, ROOM, SUBSCRIBE } from "./protocol.ts";

/** The room announces each arrival as `<nick> joined (<count> here)`. Pull the
 * head count back out so a client can wait for the room to fill. */
function rosterCount(from: string, text: string): number | null {
  if (from !== "room") return null;
  const m = text.match(/\((\d+) here\)/);
  return m ? Number(m[1]) : null;
}

/** Run one client session: subscribe, wait for `expectMembers` to be present,
 * post `line`, and collect the chat line each member sends. Resolves with the
 * transcript of real chat lines (join announcements excluded). */
export async function runClient(
  host: string,
  port: number,
  nick: string,
  line: string,
  expectMembers = 1,
  timeoutMs = 10000,
): Promise<string[]> {
  const conn = await connect(host, port);
  conn.serve().catch(() => {});

  const chatLines: string[] = [];
  let present = 0;
  let posted = false;
  let finish!: () => void;
  const done = new Promise<void>((resolve) => {
    finish = resolve;
  });

  const room = await conn.fetch(ROOM);

  function maybePost(): void {
    if (!posted && present >= expectMembers) {
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
    const count = rosterCount(from, text);
    if (count !== null) {
      present = Math.max(present, count);
      maybePost();
    } else {
      chatLines.push(`${from}: ${text}`);
      if (chatLines.length >= expectMembers) finish();
    }
    return null;
  });

  // Subscribe, handing the room a capability to our inbox.
  await conn.send(room, SUBSCRIBE, [nick, inbox]);
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

  if (chatLines.length < expectMembers) {
    throw new Error(`${nick} saw ${chatLines.length}/${expectMembers} chat lines before timeout`);
  }
  return chatLines;
}

if (import.meta.main) {
  const [host, portStr, nick, line, expectStr] = Deno.args;
  if (!host || !portStr || !nick || line === undefined) {
    console.error("usage: client.ts <host> <port> <nick> <line> [expectMembers]");
    Deno.exit(2);
  }
  try {
    await runClient(host, Number(portStr), nick, line, Number(expectStr ?? "1"));
    Deno.exit(0);
  } catch (err) {
    console.error(`client ${nick} failed: ${err instanceof Error ? err.message : err}`);
    Deno.exit(1);
  }
}
