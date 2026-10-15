// Everything Rooms says to a person, in one place.
//
// A sentence a person reads is written here and nowhere else. That keeps the
// product's voice reviewable in one set of files and gives a translator one
// place to work from. `zig build source-check` holds the rule: a reader-facing
// literal in a file this catalog owns is refused. Only the component specimen
// pages are exempt.
//
// ## Two registers, one product
//
// Rooms has two audiences. Most sessions belong to somebody a developer sent a
// link to. They did not choose OCapN, and they need four answers: what this is,
// whether it is safe, how to get in, and what to do when it breaks. Fewer
// sessions belong to an operator, who needs the protocol's own vocabulary
// exactly as it stands, because that vocabulary is what Rooms exists to show.
//
// Plain words carry the act, and the protocol word rides along as the precise
// name, never as the only name. Write "a room link (a sturdyref)" the first
// time a reader could need to match it against something a server printed, and
// "a room link" after that. Operator surfaces keep their precision and add a
// doorway that says who they are for, so a guest knows to walk past.
//
// ## Write about the reader, not about the machine
//
// The subject is the reader, or a thing the reader can see. It is not the
// session, the directory, the room, the page, or the browser. Sentences that
// make the system the subject narrate somebody else's state machine.
//
// "This durable change stopped before the session knew its final outcome" is
// about the session's knowledge. "Something you started may not have finished"
// is about the reader, says the same thing, and can be acted on. Read a
// sentence and ask who it is about. If the answer is a component, it is not
// finished.
//
// ## A true sentence that misleads is a lie
//
// "Rooms runs in this page, not on a server you sign in to" is defensible word
// by word, and a reader takes away that there is no server. They then believe
// what they type goes straight to the other people in the room. It does not.
// There is a server, it hosts the rooms, and room messages go through it.
//
// A clause like "you sign in to" protects the writer, not the reader. Say the
// whole shape instead, including the ordinary parts: there is a server, here
// is what it does, here is the part that is unusual.
//
// Three habits keep the machine from sneaking back in as the subject:
//
// - Active and short. "Messages are only saved if the server was set up to
//   save them" beats "Whether messages are kept is decided when the server is
//   started".
// - Say the consequence, not the mechanism. A reader needs to know a message
//   did not send and whether to retype it. How the session found out belongs
//   in the log.
// - Cut prose you notice. Nobody opened a chat app to read.
//
// ## A refusal does three jobs
//
// It says what happened in the reader's terms, what they can do next, and the
// exact cause for whoever is debugging, because the same screen is the
// engineering tool. `failure.ts` carries the shape. The codes and each
// refusal's one-line summary are not written here. Rust's failure definitions
// own them, generate them into `../failure_data.ts`, and
// `zig build rooms-browser-metadata-check` holds the two together.
//
// ## Adding a locale
//
// English is the only locale, so there is no message formatter. Every entry is
// a typed function or constant, so interpolation and plural choice happen
// inside the catalog where a translator can change them, never at a call site.
// A second locale is a sibling module that satisfies the same exported types.

export * from "./archive.ts";
export * from "./attached.ts";
export * from "./boot.ts";
export * from "./commands.ts";
export * from "./controls.ts";
export * from "./conversation.ts";
export * from "./directory.ts";
export * from "./failure.ts";
export * from "./help.ts";
export * from "./join.ts";
export * from "./kitchen.ts";
export * from "./link_preview.ts";
export * from "./log.ts";
export * from "./operator.ts";
export * from "./ops.ts";
export * from "./page.ts";
export * from "./rail.ts";
export * from "./recovery.ts";
export * from "./room_authority.ts";
export * from "./settings.ts";
export * from "./session.ts";
export * from "./session_settings.ts";
export * from "./writing.ts";
