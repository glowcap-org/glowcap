// An interactive rooms chat client, in Deno — the one you actually talk in.
//
// It joins the room, prints every line as it arrives, and posts whatever you
// type, until you press Ctrl-D. All the OCapN machinery lives in `room_client.ts`
// (`Room`), so this file gets to read like a chat client and nothing else.
//
//   deno run --allow-ffi --allow-read --allow-net chat.ts 127.0.0.1 9099 alice
//
// Open one terminal per person, all pointed at the same server, and chat.

import { Room } from "./room_client.ts";

const [host, portStr, nick] = Deno.args;
if (!host || !portStr || !nick) {
  console.error("usage: chat.ts <host> <port> <nick>");
  Deno.exit(2);
}

const room = await Room.join(host, Number(portStr), nick);
console.log(`(connected as "${nick}" — type a line and press enter; Ctrl-D to leave)`);

// Show the room and read your typing at the same time; when either ends — the
// room hangs up, or you press Ctrl-D — leave cleanly.
await Promise.race([showMessages(), readTyping()]);
await room.leave();

// Print each line the room sends. Its own announcements (joins, your welcome)
// get a leading "*"; everything else is "who: what".
async function showMessages(): Promise<void> {
  for await (const { from, text, system } of room.messages) {
    console.log(system ? `* ${text}` : `${from}: ${text}`);
  }
}

// Post each line you type.
async function readTyping(): Promise<void> {
  for await (const line of typedLines()) {
    if (line.length > 0) await room.say(line);
  }
}

// Yield one trimmed line at a time as you type, splitting the raw stdin stream
// on newlines and holding any half-typed tail until the rest arrives.
async function* typedLines(): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let rest = "";
  for await (const chunk of Deno.stdin.readable) {
    const text = rest + decoder.decode(chunk, { stream: true });
    const pieces = text.split("\n");
    rest = pieces.pop() ?? ""; // the last piece has no newline yet
    for (const piece of pieces) yield piece.trim();
  }
  if (rest.trim().length > 0) yield rest.trim();
}
