/**
 * What one word in the Reference says.
 *
 * Every section of the Reference is a table keyed by the type it explains, so
 * this is the value side of all of them. A section adds a field when it has a
 * fact of its own to carry and nowhere else to read it from: the transports
 * table adds how far each netlayer can be trusted. Attribution adds nothing,
 * because the kind of evidence behind a word is a fact about the word that the
 * schema already holds.
 */
export type ReferenceEntry = {
  /** What the word means, in the words a person would say it in. Full
   *  sentences: this is the thing a reader came to read. */
  readonly says: string;
  /** The quiet second line. Where the word shows up, or the one caveat a
   *  reader needs before they go looking for it. */
  readonly aside?: string;
};
