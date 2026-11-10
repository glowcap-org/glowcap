// IRC formatting, as it arrives over a bridge. IRC carries emphasis as
// control characters rather than as marks a person types: a byte turns bold
// on, the same byte turns it off again, and a reset clears everything. They
// are toggles rather than delimiters, so they nest by state and not by
// pairing, and a line may leave one on at its end.
//
// Nothing here writes them. This is the reading half, so a line relayed from an
// IRC channel arrives looking the way its author wrote it rather than carrying
// invisible characters that show as nothing and mean something.
const IRC_BOLD = "\x02";
const IRC_COLOUR = "\x03";
const IRC_MONO = "\x11";
const IRC_REVERSE = "\x16";
const IRC_RESET = "\x0F";
const IRC_ITALIC = "\x1D";
const IRC_STRIKE = "\x1E";
const IRC_UNDERLINE = "\x1F";

/** Whether a line carries any IRC formatting at all, so the ordinary path is
 * untouched for the messages this app writes itself. */
export function hasIrcFormatting(text: string): boolean {
	// deno-lint-ignore no-control-regex
	return /[\x02\x03\x0F\x11\x16\x1D\x1E\x1F]/.test(text);
}

/** One stretch of a line, with the emphasis in force across it. */
export interface IrcRun {
	text: string;
	bold: boolean;
	italic: boolean;
	underline: boolean;
	strike: boolean;
	mono: boolean;
	/** mIRC's numbered palette, as written. Kept as the number rather than a
	 * colour because what those numbers mean is a decision for the stylesheet,
	 * the same way every other colour in this interface is. */
	fg?: number;
	bg?: number;
}

/** Split a line into runs by the formatting in force across each.
 *
 * A toggle flips its own state and leaves the rest alone. A reset clears all of
 * them. Reverse swaps foreground and background, which is how IRC says
 * "highlight", kept as the swap rather than resolved here, because the palette
 * it swaps within belongs to the stylesheet. */
export function ircRuns(text: string): IrcRun[] {
	const runs: IrcRun[] = [];
	let bold = false, italic = false, underline = false, strike = false, mono = false;
	let fg: number | undefined;
	let bg: number | undefined;
	let held = "";
	const cut = () => {
		if (held === "") return;
		runs.push({ text: held, bold, italic, underline, strike, mono, fg, bg });
		held = "";
	};
	for (let at = 0; at < text.length; at++) {
		const c = text[at];
		if (c === IRC_BOLD) {
			cut();
			bold = !bold;
			continue;
		}
		if (c === IRC_ITALIC) {
			cut();
			italic = !italic;
			continue;
		}
		if (c === IRC_UNDERLINE) {
			cut();
			underline = !underline;
			continue;
		}
		if (c === IRC_STRIKE) {
			cut();
			strike = !strike;
			continue;
		}
		if (c === IRC_MONO) {
			cut();
			mono = !mono;
			continue;
		}
		if (c === IRC_REVERSE) {
			cut();
			[fg, bg] = [bg, fg];
			continue;
		}
		if (c === IRC_RESET) {
			cut();
			bold =
				italic =
				underline =
				strike =
				mono =
					false;
			fg = bg = undefined;
			continue;
		}
		if (c === IRC_COLOUR) {
			cut();
			// `\x03` alone clears colour; otherwise up to two digits of foreground
			// and, after a comma, up to two of background.
			const rest = text.slice(at + 1);
			const named = rest.match(/^(\d{1,2})(?:,(\d{1,2}))?/);
			if (named === null) {
				fg = bg = undefined;
				continue;
			}
			fg = Number(named[1]);
			bg = named[2] === undefined ? bg : Number(named[2]);
			at += named[0].length;
			continue;
		}
		held += c;
	}
	cut();
	return runs;
}
