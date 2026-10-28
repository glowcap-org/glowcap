---
type: static
description: How a durable actor gets a saved secret name that peers can fetch, and how serving those names works.
audience: human
sources:
  - resource: /src/loam/hosting/
---

# Durable names

A publication gives a [durable actor](actors.md) a secret name that peers can
fetch: the swiss number in a sturdyref, the saved reference a peer uses to
reach an object later. The name is saved on disk, so a sturdyref keeps
working after a restart. Nothing loads at startup, and a fetch wakes only the
actor it names.

## Serving names

Register `hosting.publication.schema` with the [Store](store.md) and call
`publication.listen(attachment, options)` after opening it. One attachment
answers fetches for the whole Host. Startup creates no in-memory entries or
actor endpoints. A fetch looks up its name, reads the actor's saved record
through the shared cache, and restores only that actor. Fetches of the same
name at the same time share one lookup and read. `publication.restore` still
loads a name ahead of time when your program needs it in memory.

## Publishing a name

Inside a transaction your program runs, outside any call,
`publication.stage(attachment, entropy, held_target)` saves a rooted record
for the name and adds the secret name to the index in the same commit. Your
program supplies secure random bytes. A name never changes and is never given
to another actor, even after it is retired and collected. Stores must use the
current Loam metadata format, which carries this index. That format is Loam's
own and separate from the engine's file format.

## Running lookups in your storage loop

Run `Attachment.Work.lookup` through `backend.lookup` and pass its result to
`attachment.completeLookup`, alongside the read and write work. Each result is
tagged with the Store and revision it read, and a stale result is retried.

- By default, at most <!-- value ../../src/loam/hosting/discovery.zig max_names -->16<!-- /value --> distinct names and <!-- value ../../src/loam/hosting/discovery.zig max_fetches -->64<!-- /value --> fetches can wait at once. Past that,
  fetches are refused. One peer holds at most `max_fetches_per_origin` of
  those fetch slots, a quarter of `max_fetches` unless the listener sets it,
  so a flood from one peer leaves room for the others. A local fetch is its
  own origin, so the bound never reaches local callers.
- Listening allocates the lookup table and two bounded arrays, and each
  waiting name holds its 16 secret bytes.
- A submitted lookup runs to completion even if everyone waiting on it
  leaves.
- Each name keeps a permanent index entry, whose size
  [owner cleanup](access.md#bounded-owner-cleanup) gives. Collection keeps
  that entry when it frees the name's record.

## Retiring a name

To stop a name from answering fetches, load its current record, begin a
transaction, call `stageRetirement`, and submit through `attachment.submit`.
Fetches stop finding the name once the retirement commits, and stay stopped
if the outcome is unknown. The attachment's write queue finishes the job, and
a retirement that recovery shows never landed makes the name answer again.

Retiring only stops new fetches. References peers already hold keep working,
and a rooted record keeps its target alive across a restart. A bare object
ID keeps nothing alive.

While an outcome is unknown, Loam hides the name's existing Host entry and
keeps its actor alive. Recovery either removes that entry or makes the same
entry answer again. This needs no allocation or disk read, even when the
publication record has left the cache. A name that was not in memory stays
on demand. Each lookup checks the current record, so a stale lookup cannot
bring a retired name back.

Host shutdown finishes these storage outcomes too. Finishing restores a name
whose retirement never committed. Cancellation removes its in-memory entry
and leaves the unchanged durable record available after a restart.

## Destroying the attachment

Finish waiting calls and storage work before `attachment.destroy()`, which
returns `Busy` while any call, read, write, reference save, effect
continuation, or unresolved publication retirement remains.
Destroying the attachment closes it to new calls. Capabilities peers still
hold keep a little routing data until the Host releases them, answer
`AttachmentClosed`, and never touch the Store again.

Destroy the attachment before you deinitialize the Store or Host, and do not
use its pointer afterward.

[ADR-0007](../decisions/adr/ADR-0007-sturdyrefs-and-publication.md)
records this design and the alternatives.
