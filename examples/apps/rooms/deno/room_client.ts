// A small, friendly client for the rooms chat, built on pancake actors.
//
// This is the layer that knows about OCapN — and on the new connection API it is
// barely a layer at all: connect, fetch the room by name, spawn an inbox the room
// can call back, subscribe by handing it that capability, and surface the room's
// callbacks as a stream. Everything above it — the terminal client, the web UI —
// reads like an app, not like a protocol.
//
//   const room = await Room.join("127.0.0.1", 9099, "alice");
//   room.say("hello");
//   for await (const msg of room.messages) console.log(msg.from, msg.text);
//   await room.leave();

import { connect, type Connection, type Ref } from "../../../../bindings/deno/pancake.ts";
import { NOTIFY, POST, ROOM, SUBSCRIBE } from "./protocol.ts";

/** One line in the room. `system` is true for the room's own announcements (a
 * member joining, your welcome); otherwise `from` is the member who said it. */
export interface Message {
  from: string;
  text: string;
  system: boolean;
}

/** A membership in a chat room. Get one with `Room.join`, read `messages`, call
 * `say`, and `leave` when you are done. */
export class Room {
  #conn: Connection;
  #room: Ref;
  // Captured synchronously by the ReadableStream `start` callback.
  #lines!: ReadableStreamDefaultController<Message>;
  #leaving = false;

  /** The lines the room sends you, in order, as an async stream. The stream ends
   * when you `leave` or the room hangs up. */
  readonly messages: ReadableStream<Message>;

  private constructor(conn: Connection, room: Ref) {
    this.#conn = conn;
    this.#room = room;
    this.messages = new ReadableStream<Message>({
      start: (controller) => {
        this.#lines = controller;
      },
    });
  }

  /** Join the room at `host:port` as `nick`: connect, fetch the room by name,
   * publish an inbox the room can call back, and subscribe by handing it that
   * capability. */
  static async join(host: string, port: number, nick: string): Promise<Room> {
    const conn = await connect(host, port);
    // Start the inbound loop before fetching, so the fetch's resolution arrives.
    conn.serve().catch(() => {});
    const room = await conn.fetch(ROOM);
    const self = new Room(conn, room);

    // The room calls this back with every line; surface it on `messages`.
    const inbox = conn.spawn((verb, args) => {
      if (verb !== NOTIFY) throw new Error(`inbox has no method ${verb}`);
      const from = typeof args[0] === "string" ? args[0] : "?";
      const text = typeof args[1] === "string" ? args[1] : "";
      self.#emit(from, text);
      return null;
    });

    // End the message stream when the connection closes.
    conn.serve().finally(() => self.#endStream());

    // Subscribe, handing the room a capability to our inbox. The welcome it
    // returns is our first line.
    const welcome = await conn.send(room, SUBSCRIBE, [nick, inbox]);
    self.#emit("room", typeof welcome === "string" ? welcome : "joined");
    return self;
  }

  /** Say a line to everyone in the room. */
  async say(text: string): Promise<void> {
    await this.#conn.send(this.#room, POST, [text]);
  }

  /** Leave the room and release the connection. */
  async leave(): Promise<void> {
    this.#leaving = true;
    this.#conn.close();
    await this.#conn.serve().catch(() => {});
  }

  #emit(from: string, text: string): void {
    try {
      this.#lines.enqueue({ from, text, system: from === "room" });
    } catch {
      // The stream is already closed (we have left) — drop the late line.
    }
  }

  #endStream(): void {
    if (!this.#leaving) console.error("rooms: the room closed the connection");
    try {
      this.#lines.close();
    } catch {
      // Already closed.
    }
  }
}
