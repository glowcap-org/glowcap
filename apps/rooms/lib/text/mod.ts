// Everything Rooms says to a person, in one place.
//
// Until this existed there was no set of Rooms' words to look at. They were
// JSX literals, literals in this directory's siblings, and — for the failures a
// reader meets most often — Rust. Nobody could review the product's voice,
// because reviewing it meant reading sixty files and guessing which strings
// reached a screen; and nobody could translate it for the same reason.
//
// So the rule is that a sentence a person reads is written here and nowhere
// else. `zig build source-check` holds it: a reader-facing literal in a file
// this catalog owns is refused, and the list of files not yet moved is closed
// and goes to zero.
//
// ## Two registers, one product
//
// Rooms has two audiences and they arrive in a fixed order. Most sessions are
// somebody a developer sent a link to: they did not choose OCapN, and they need
// four answers — what this is, whether it is safe, how to get in, and what to do
// when it breaks. Fewer sessions are an operator, who needs the protocol's own
// vocabulary exactly as it stands, because that vocabulary is what Rooms exists
// to show.
//
// Neither is served by picking one altitude. So: **plain words carry the act,
// and the protocol word rides along as the precise name, never as the only
// name.** Write "a room link (a sturdyref)" the first time a reader could need
// to match it against something a server printed, and "a room link" every time
// after. The operator surfaces keep their precision; what they gain is a
// doorway that says who they are for, so a guest knows to walk past.
//
// ## Write about the reader, not about the machine
//
// The deeper habit, and the one that survived a first pass at the vocabulary:
// nearly every sentence in this product had the system as its subject. The
// session knew things. The directory introduced people and stepped out. The
// room kept messages. This browser refused to save. A reader appears in those
// sentences as an object if at all, and what they are handed is a narration of
// somebody else's state machine.
//
// > **The subject is the reader, or a thing the reader can see. Not the
// > session, the directory, the room, the page, or the browser.**
//
// ## A true sentence that misleads is a lie
//
// The costliest failure here is not jargon and not selling. It is the sentence
// built to survive an audit while leaving the reader with the wrong picture.
// "Rooms runs in this page, not on a server you sign in to" was one. Every word
// of it is defensible and nobody reads it that carefully: what a reader takes
// away is that there is no server, and then they believe what they type in a
// room goes straight to the other people in it. It does not. There is a server,
// it hosts the rooms, and room messages go through it.
//
// The qualifier doing the load-bearing work — "you sign in to" — is the tell.
// When a sentence needs a clause like that to be true, the clause is not
// protecting the reader, it is protecting the writer. Say the whole shape
// instead, including the ordinary parts: there is a server, here is what it
// does, here is the part that is unusual. A reader who is told the boring truth
// can act on it; a reader who is told a clever one cannot.
//
// "This durable change stopped before the session knew its final outcome" is
// about the session's knowledge. "Something you started may not have finished"
// is about the reader, says the same thing, and can be acted on. The test is to
// read a sentence and ask who it is about; if the answer is a component, it is
// not finished.
//
// Three habits that follow from it, because they are how the machine sneaks
// back in as the subject:
//
// - **Active, and short.** "Whether messages are kept is decided when the
//   server is started" buries its subject behind a passive. "Messages are only
//   saved if the server was set up to save them" does not.
// - **Say the consequence, not the mechanism.** A reader needs to know their
//   message did not send and whether to retype it. How the session discovered
//   that is the log's business.
// - **If you notice the prose, cut it.** A sentence that is pleased with itself
//   is a sentence written for its author. This is a chat app; nobody opened it
//   to read.
//
// ## A refusal does three jobs
//
// What happened, in the reader's terms. What they can do next. And the exact
// cause, kept, for whoever is debugging — because the same screen is the
// engineering tool. A refusal that only does the third is a raw error code with
// a sentence's job, and it is the commonest defect this catalog was written to
// end. `failure.ts` carries the shape. The codes and each refusal's one-line
// summary are not written here at all: Rust's failure definitions are the one
// authority, generated into `../failure_data.ts` and held to it by
// `zig build rooms-browser-metadata-check`.
//
// ## Adding a locale
//
// English is the reference and the only one today, so there is no message
// formatter here: with one locale it would be indirection that buys nothing.
// What makes a second locale cheap is the shape rather than a runtime — every
// entry is a typed function or constant, so interpolation and plural choice
// happen *inside* the catalog where a translator can change them, never at a
// call site where a translator cannot reach. A second locale is a sibling
// module satisfying the same exported types.

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
