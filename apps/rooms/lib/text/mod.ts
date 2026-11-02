// Everything Rooms says to a person, in one place.
//
// A sentence a person reads is written here and nowhere else, so the product's
// voice is reviewable in one set of files and a translator has one place to
// work from. `zig build source-check` refuses a reader-facing literal in a file
// this catalog owns; only the component specimen pages are exempt. The
// doc-writing skill's reader-voice section holds the judgment for the words.
//
// A refusal says what happened in the reader's terms, what they can do next,
// and the exact cause for whoever is debugging (`failure.ts`). The codes and
// each refusal's one-line summary come from Rust's failure definitions,
// generated into `../failure_data.ts` and held together by
// `zig build rooms-browser-metadata-check`.
//
// English is the only locale. Every entry is a typed function or constant, so
// interpolation and plural choice happen inside the catalog, never at a call
// site, and a second locale is a sibling module with the same exported types.

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
