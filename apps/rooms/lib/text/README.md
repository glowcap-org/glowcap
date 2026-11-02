# Everything Rooms says to a person

A sentence a person reads is written in this directory and nowhere else, so
the product's voice is reviewable in one set of files and a translator has one
place to work from. `zig build source-check` refuses a reader-facing literal in
a file this catalog owns. Only the component specimen pages are exempt. The
doc-writing skill's reader-voice section holds the judgment for the words.

A refusal says what happened in the reader's terms, what they can do next, and
the exact cause for whoever is debugging (`failure.ts`). The codes and each
refusal's one-line summary come from Rust's failure definitions, generated
into `../failure_data.ts` and held together by
`zig build rooms-browser-metadata-check`.

English is the only locale. Every entry is a typed function or constant, so
interpolation and plural choice happen inside the catalog, never at a call
site. A page imports the file that owns its words, and a second locale is a
sibling directory with the same exported names.
