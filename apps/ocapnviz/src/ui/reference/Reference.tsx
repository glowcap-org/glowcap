/**
 * The Reference: one place that says what every word the app attaches to a
 * peer or a session means.
 *
 * A section is one closed set. Its rows come from a table keyed by the type
 * the schema declares, so the words in front of a reader are the words the
 * document can hold, and a value added to the schema cannot ship without an
 * explanation. Adding a section is one row in `REFERENCE_SECTIONS` plus its
 * table.
 *
 * The sections read as the life of a session: it is dialed over a transport,
 * the hello settles a version and a codec, the peers behind it have a profile,
 * and the session sits in a state. Attribution comes first because it is the
 * one word here that changes the picture rather than describing it, and it is
 * where a confused reader most often is.
 *
 * The sidebar Legend and this are two different jobs. The Legend is the
 * at-a-glance key that says which color, line and thickness stand for what,
 * and it is on screen the whole time. The Reference says what the words
 * themselves mean, at a length no side pane can hold, and it opens when a
 * reader asks. Each Legend group names a property, and the Reference has the
 * section that explains that property's values.
 */

import { useRef } from "react";
import { captpVersionLabel } from "../../schema/topology.ts";
import { ATTRIBUTION_STANDING, UNATTRIBUTED_WORD } from "../../schema/session-end.ts";
import {
  CAPTP_VERSION_ROWS,
  CODEC_ROWS,
  PROFILE_ROWS,
  SESSION_STATE_ROWS,
  TRANSPORT_LADDER,
  TRANSPORT_ROWS,
  TRANSPORT_VERDICT,
  TRANSPORTS_PAGE_NOTE,
  TRANSPORTS_PAGE_URL,
  type TransportStanding,
} from "./vocabulary.ts";
import {
  ATTRIBUTION_LADDER,
  ATTRIBUTION_NOTES,
  ATTRIBUTION_ROWS,
  ATTRIBUTION_STANDING_WORD,
  LOOSE_END_TEXT,
} from "./endpoint-attribution.ts";
import type { ReferenceEntry } from "./entry.ts";
import { Dialog } from "../Dialog.tsx";
import { attributionChipStyle, attributionStandingStyle, stateChipBase } from "../EntityChips.tsx";
import { HelpGlyph } from "../glyphs.tsx";
import { c, FONT, PANEL, SIZE, SPACE } from "../tokens.ts";
import { segmentCellClass } from "../tokens.ts";

export type ReferenceSectionId =
  | "attribution"
  | "transports"
  | "versions"
  | "codecs"
  | "profiles"
  | "states";

type ReferenceSection = {
  readonly id: ReferenceSectionId;
  /** The word on the picker. One or two syllables, because six of them stand
   *  in a row. */
  readonly tab: string;
  /** The one thing a reader should take away from this section. */
  readonly summary: string;
  readonly Body: () => React.ReactElement;
};

/** What the whole panel is for, said once above the picker so a reader who
 *  arrived confused knows what the six sections are drawn from. */
const SUBTITLE = "What every word this app attaches to a peer or a session means.";

/** The sections, in the order they are offered. */
export const REFERENCE_SECTIONS: readonly ReferenceSection[] = [
  {
    id: "attribution",
    tab: "Attribution",
    summary: "Every session end carries a designator, which is the name it claims " +
      "on the wire. What backed that claim decides whether the end joins a " +
      "peer on the stage or stands there as a node of its own. Each word " +
      "below is backed by a signature somebody checked, by a party speaking " +
      "for itself, or by this viewer's own inference.",
    Body: AttributionBody,
  },
  {
    id: "transports",
    tab: "Transports",
    summary: "The netlayer a session's bytes ride, and how far each one can be " +
      "trusted.",
    Body: TransportBody,
  },
  {
    id: "versions",
    tab: "Versions",
    summary: "The CapTP version the two ends agreed on when the session opened.",
    // Keyed by the tag the document stores, read out under the word the
    // handshake uses, which is the word every other surface shows too.
    Body: () => (
      <WordRows
        rows={CAPTP_VERSION_ROWS}
        wordOf={(tag) => captpVersionLabel(tag)}
      />
    ),
  },
  {
    id: "codecs",
    tab: "Codecs",
    summary: "How a session's messages are written on the wire.",
    Body: () => <WordRows rows={CODEC_ROWS} />,
  },
  {
    id: "profiles",
    tab: "Profiles",
    summary: "The implementation behind a peer, as far as the viewer is told.",
    Body: () => <WordRows rows={PROFILE_ROWS} />,
  },
  {
    id: "states",
    tab: "States",
    summary: "Where a session stands, from its first hello to its last frame.",
    Body: () => <WordRows rows={SESSION_STATE_ROWS} />,
  },
];

/** Where the Reference opens when nobody named a section. */
export const DEFAULT_REFERENCE_SECTION: ReferenceSectionId = "attribution";

/** Top-bar button that opens the Reference. An icon among icons, with the
 *  conventional picture for help. */
export function ReferenceButton({ onOpen }: { onOpen: () => void }) {
  const label = "Reference — what every word in this app means";
  return (
    <button
      type="button"
      className="ocv-btn is-ghost is-icon"
      onClick={onOpen}
      title={label}
      aria-label="Reference"
    >
      <HelpGlyph />
    </button>
  );
}

/** The Reference itself: the picker, the section a reader has picked, and the
 *  way out. */
export function ReferenceDialog(
  { section, onPick, onClose }: {
    section: ReferenceSectionId;
    onPick: (section: ReferenceSectionId) => void;
    onClose: () => void;
  },
) {
  const pickedRef = useRef<HTMLButtonElement | null>(null);
  const current = REFERENCE_SECTIONS.find((s) => s.id === section) ??
    REFERENCE_SECTIONS[0]!;
  return (
    <Dialog
      title="Reference"
      maxWidth={820}
      autoFocusRef={pickedRef}
      onPrimary={onClose}
      onDismiss={onClose}
      footer={
        <button type="button" className="ocv-btn" onClick={onClose}>
          Close
        </button>
      }
    >
      <p style={subtitleText}>{SUBTITLE}</p>
      <div
        className="ocv-segment"
        role="radiogroup"
        aria-label="Reference section"
        style={{ marginBottom: SPACE.md }}
      >
        {REFERENCE_SECTIONS.map((s) => (
          <button
            key={s.id}
            type="button"
            role="radio"
            aria-checked={s.id === current.id}
            ref={s.id === current.id ? pickedRef : null}
            className={segmentCellClass(s.id === current.id)}
            onClick={() => onPick(s.id)}
          >
            {s.tab}
          </button>
        ))}
      </div>
      <div style={scroller}>
        <p style={summaryText}>{current.summary}</p>
        <current.Body />
      </div>
    </Dialog>
  );
}

function AttributionBody() {
  return (
    <>
      <div style={{ ...block, ...badgeGrid }}>
        {byLadder(
          ATTRIBUTION_ROWS,
          (word) => ATTRIBUTION_STANDING[word],
          ATTRIBUTION_LADDER,
        )
          .map(([word, row, standing], i) => (
            <Row
              key={word}
              word={word}
              entry={row}
              divided={i > 0}
              badge={
                <span style={attributionStandingStyle(standing)}>
                  {ATTRIBUTION_STANDING_WORD[standing]}
                </span>
              }
            />
          ))}
      </div>
      {
        /* The fifth answer wears the chip itself rather than a word and a
        badge, because with nothing stored there is no word to put in the
        first column and the chip is already both. It is the same amber a
        reader saw on the end that sent them here. */
      }
      <div style={block}>
        <div>
          <span style={attributionChipStyle(undefined)}>
            {UNATTRIBUTED_WORD}
          </span>
        </div>
        <p style={paragraph}>{LOOSE_END_TEXT}</p>
      </div>
      <div style={notes}>
        {ATTRIBUTION_NOTES.map((note) => <p key={note} style={noteText}>{note}</p>)}
      </div>
    </>
  );
}

function TransportBody() {
  return (
    <>
      <div style={{ ...block, ...badgeGrid }}>
        {byLadder(TRANSPORT_ROWS, (_, row) => row.standing, TRANSPORT_LADDER)
          .map(([word, row, standing], i) => (
            <Row
              key={word}
              word={word}
              entry={row}
              divided={i > 0}
              badge={
                <span style={verdictStyle(standing)}>
                  {TRANSPORT_VERDICT[standing]}
                </span>
              }
            />
          ))}
      </div>
      <div style={notes}>
        <p style={noteText}>{TRANSPORTS_PAGE_NOTE}</p>
        <a
          className="ocv-btn"
          href={TRANSPORTS_PAGE_URL}
          target="_blank"
          rel="noreferrer"
          style={{ width: "fit-content", textDecoration: "none" }}
        >
          Choosing a transport
        </a>
      </div>
    </>
  );
}

/** The rows of a table, ordered by the ladder its standings are ranked on.
 *
 * Two sections rank their rows: one by what kind of evidence a word is, one
 * by how far a netlayer can be trusted. Reading the order off the ladder means
 * a row added to the middle of a table still lands beside the rows that stand
 * where it does, instead of leaving the order to how the table happens to be
 * written. A standing missing from the ladder drops its rows, and
 * `reference.test.ts` is what refuses that. */
function byLadder<K extends string, R extends ReferenceEntry, S extends string>(
  rows: Record<K, R>,
  standingOf: (word: K, row: R) => S,
  ladder: readonly S[],
): [word: K, row: R, standing: S][] {
  const entries = (Object.keys(rows) as K[]).map(
    (word) => [word, rows[word], standingOf(word, rows[word])] as [K, R, S],
  );
  return ladder.flatMap((rung) => entries.filter(([, , s]) => s === rung));
}

/** A section whose rows are a word and a sentence, which is most of them.
 *
 * A table is keyed by the type the schema declares, and for most sets that
 * key is also the word a reader sees. Where the two differ, `wordOf` names
 * the word the rest of the app shows, because a reference that teaches an
 * identifier nobody is shown has explained the wrong thing. */
function WordRows<K extends string>(
  { rows, wordOf }: {
    rows: Record<K, ReferenceEntry>;
    wordOf?: (key: K) => string;
  },
) {
  // `Object.keys` answers `string[]` whatever the record is keyed by, and the
  // keys of a table written out arm by arm are exactly its type. Said once
  // here so a section can hand in a `wordOf` that reads its own key type.
  const keys = Object.keys(rows) as K[];
  return (
    <div style={{ ...block, ...rowsGrid }}>
      {keys.map((key, i) => (
        <Row
          key={key}
          word={wordOf ? wordOf(key) : key}
          entry={rows[key]}
          divided={i > 0}
        />
      ))}
    </div>
  );
}

/** One row: the stored word, what it means, and anything quieter that goes
 *  with it. The word is mono because it is a value a document holds, and the
 *  sentence is sans because a person wrote it. */
function Row(
  { word, entry, badge, divided = false }: {
    word: string;
    entry: ReferenceEntry;
    badge?: React.ReactNode;
    /** Whether a rule is drawn above this row. Every cell takes it, because
     *  a grid row is cells and not an element, so the line is only whole if
     *  each of them draws its own share. */
    divided?: boolean;
  },
) {
  const rule = divided ? dividedCell : undefined;
  return (
    <>
      <span style={{ ...wordCell, ...rule }}>{word}</span>
      {badge !== undefined && <span style={{ ...badgeCell, ...rule }}>{badge}</span>}
      <span style={rule}>
        <span style={saysText}>{entry.says}</span>
        {entry.aside !== undefined && <span style={asideText}>{entry.aside}</span>}
      </span>
    </>
  );
}

/** How every sentence in the panel breaks. `pretty` asks the browser to pull a
 *  word back from the last line rather than leave one there alone, which is
 *  the ordinary outcome here and not the rare one: the panel is wide and the
 *  sentences are short, so most of them end a word or two into a line. Said
 *  once, because a widow fixed in one paragraph style and not the next is the
 *  same defect as no fix at all. */
const proseWrap = { textWrap: "pretty" } satisfies React.CSSProperties;

/** How far a line runs where nothing else stops it.
 *
 * A sentence set to this panel's full width runs past a hundred characters,
 * which is further than an eye tracks back comfortably, so the prose that
 * spans the panel stops here instead. A row's sentence takes no cap: the grid
 * has already put a word and a badge to its left, and its column is inside a
 * comfortable measure on its own. Capping it a second time only breaks lines
 * earlier than the layout needs and makes the rows taller than they read. */
const measured = {
  ...proseWrap,
  maxWidth: "68ch",
} satisfies React.CSSProperties;

/** How tall one line of prose stands. Said once because a row's grid sets it
 *  for every cell at once, and the badge column reads it back to stand exactly
 *  one line tall beside the sentence it labels. */
const LINE = 1.45;

const subtitleText = {
  ...measured,
  fontFamily: FONT.sans,
  fontSize: SIZE.base,
  color: c.textMuted,
  margin: 0,
  marginBottom: SPACE.md,
} satisfies React.CSSProperties;

// The panel is capped and the sections are not, so the body is what scrolls.
// A flex child will not shrink below its own content until its `min-height`
// says it may, and this one says it may down to a floor: past that the
// section scrolls instead of pushing the footer off the panel.
//
// The floor is a number rather than a token because it is a dialog dimension,
// which is the unit `maxWidth` beside it is already stated in. It holds the
// four short sections at one height, so picking Codecs after Attribution does
// not collapse the panel to a stub. It gives way on a short window, where a
// floor the panel's own cap cannot honour would push the footer out of the
// box.
//
// The two rules are the scroll region's own edges. Without them a long
// section slides under the picker and out at the footer with nothing to say
// where it went.
const scroller = {
  overflowY: "auto",
  minHeight: "min(300px, 40vh)",
  flex: 1,
  borderTop: `1px solid ${c.divider}`,
  borderBottom: `1px solid ${c.divider}`,
  paddingTop: SPACE.md,
  paddingBottom: SPACE.md,
  paddingRight: SPACE.md,
} satisfies React.CSSProperties;

const summaryText = {
  ...measured,
  fontFamily: FONT.sans,
  fontSize: SIZE.base,
  color: c.text,
  lineHeight: LINE,
  margin: 0,
  marginBottom: SPACE.lg,
} satisfies React.CSSProperties;

// A group of rows sits a step off the panel it is on, which is what
// `surfaceSubtle` is for, with a hairline around it. Two sections' worth of
// rows on one flat surface run together; lifting each group says where one
// closed set ends and the next begins without a heading having to carry it
// alone.
//
// The inset is one step below the gap to the next group, which is the whole
// argument of the spacing scale: a group reads as a group when what is inside
// it sits closer than what is beside it.
const block = {
  ...PANEL,
  marginBottom: SPACE.lg,
  border: `1px solid ${c.border}`,
  padding: SPACE.md,
} satisfies React.CSSProperties;

// The column gap is carried as padding on the cells rather than by
// `columnGap`, so that a row's hairline is one unbroken line across the
// section. A real gap is empty space no cell can draw a border through, and
// the rule would arrive as one segment per column.
//
// Both columns are sized to what they hold. A word column stated as a width
// is a number that has to be kept in step with the longest word in the table,
// and one section's longest word is three times another's; `max-content` is
// that number, read off the words themselves.
//
// The cells stretch rather than sit on a shared baseline. Baseline alignment
// moves each cell's box to line its text up, which puts the border those
// boxes draw at a different height per column, and the one rule the padding
// above was there to make whole arrives as a step. Stretched, every cell in a
// row starts at the same edge, so the line is straight by construction and
// the text lines up because the cells share one line height instead.
const rowsGrid = {
  display: "grid",
  gridTemplateColumns: "max-content minmax(0, 1fr)",
  columnGap: 0,
  rowGap: SPACE.sm,
  fontSize: SIZE.base,
  lineHeight: LINE,
} satisfies React.CSSProperties;

// The two sections that rank their rows put the rank between the word and the
// sentence, so the ranking reads down one column. The badge column is sized
// to its content for the reason the word column is: the chip inside it clips
// with an ellipsis rather than wrapping, so a longer verdict added later would
// be quietly cut off by any number written here.
const badgeGrid = {
  ...rowsGrid,
  gridTemplateColumns: "max-content max-content minmax(0, 1fr)",
} satisfies React.CSSProperties;

/** The hairline that separates one row from the next, drawn on every cell of
 *  the row so it reads as a single rule. The first row of a group carries
 *  none: a line above the first item would cut it off from whatever
 *  introduces the group. */
const dividedCell = {
  // `border` and not `divider`: a divider is drawn to read against the panel
  // surface, and these rows sit on a raised one, where it comes within a shade
  // of the background it is meant to be seen on. The rule that separates rows
  // inside a group has to be picked for the surface the group is on.
  borderTop: `1px solid ${c.border}`,
  // Matches the grid's own row gap, so the rule sits centered between the row
  // above and the row below rather than crowding one of them.
  paddingTop: SPACE.sm,
} satisfies React.CSSProperties;

const wordCell = {
  fontFamily: FONT.mono,
  fontSize: SIZE.sm,
  color: c.text,
  overflowWrap: "anywhere",
  paddingRight: SPACE.lg,
} satisfies React.CSSProperties;

// One line tall and pinned to the row's start, so the chip sits against the
// sentence's first line rather than riding the middle of a wrapped row.
// `flex-start` plus the half-leading of that line (not geometric center): an
// uppercase chip centered in the line box reads a step above the sentence.
const badgeCell = {
  display: "flex",
  alignItems: "flex-start",
  alignSelf: "start",
  height: `${LINE}em`,
  paddingTop: `${(LINE - 1) / 2}em`,
  paddingRight: SPACE.lg,
  boxSizing: "border-box",
} satisfies React.CSSProperties;

const saysText = {
  ...proseWrap,
  fontFamily: FONT.sans,
  fontSize: SIZE.base,
  color: c.text,
  lineHeight: LINE,
} satisfies React.CSSProperties;

const asideText = {
  ...proseWrap,
  display: "block",
  fontFamily: FONT.sans,
  fontSize: SIZE.sm,
  color: c.textMuted,
  lineHeight: LINE,
  marginTop: SPACE.xs,
} satisfies React.CSSProperties;

const notes = {
  display: "flex",
  flexDirection: "column",
  gap: SPACE.md,
  borderTop: `1px solid ${c.divider}`,
  paddingTop: SPACE.md,
} satisfies React.CSSProperties;

const noteText = {
  ...measured,
  fontFamily: FONT.sans,
  fontSize: SIZE.base,
  color: c.textMuted,
  lineHeight: LINE,
  margin: 0,
} satisfies React.CSSProperties;

const paragraph = {
  ...noteText,
  color: c.text,
  marginTop: SPACE.sm,
} satisfies React.CSSProperties;

/** Green, amber and red are states of the thing described, and a verdict is
 *  exactly that: where the netlayer stands, said about the netlayer. */
function verdictStyle(standing: TransportStanding): React.CSSProperties {
  const [bg, fg] = standing === "production"
    ? [c.positiveSoft, c.positive]
    : standing === "trusted-network"
    ? [c.warningSoft, c.warning]
    : [c.dangerSoft, c.danger];
  return { ...stateChipBase, background: bg, color: fg };
}
