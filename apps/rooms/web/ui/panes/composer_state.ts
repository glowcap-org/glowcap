/** The composer's own state machine: which tray or focus phase it is in, and
 * the inline-completion trio of caret, selection, and dismissal. Every field
 * moves only through `composerReducer`, so a completion list can never keep a
 * selection a newer list has outlived, and a recall never survives the edit
 * that replaced it.
 *
 * What the store owns (the draft, the conversation, the changing line) stays
 * out of here: those arrive as props and store reads, and the effects keyed
 * on them stay effects, because the reducer cannot see a store-driven token
 * change. */

export type ComposerState = {
	emojiOpen: boolean;
	focused: boolean;
	recovering: boolean;
	caret: number;
	picked: number;
	dismissedAt: number | null;
	recalled: string | null;
};

/** One transition. Reader actions are verbs. The token effect delivers the
 * completion token's identity, and the recall paths deliver the line. */
export type ComposerAction =
	| { kind: "tray"; open: boolean }
	| { kind: "focused"; held: boolean }
	| { kind: "recovering"; held: boolean }
	| { kind: "caret"; caret: number }
	| { kind: "pick"; picked: number }
	| { kind: "pickStepped"; step: number; count: number }
	| { kind: "token"; id: string | null }
	| { kind: "dismissed"; at: number | null }
	| { kind: "recalled"; line: string | null };

export const initialComposerState: ComposerState = {
	emojiOpen: false,
	focused: false,
	recovering: false,
	caret: 0,
	picked: 0,
	dismissedAt: null,
	recalled: null,
};

export function composerReducer(state: ComposerState, action: ComposerAction): ComposerState {
	switch (action.kind) {
		case "tray":
			return { ...state, emojiOpen: action.open };
		case "focused":
			return { ...state, focused: action.held };
		case "recovering":
			return { ...state, recovering: action.held };
		case "caret":
			return { ...state, caret: action.caret };
		case "pick":
			return { ...state, picked: action.picked };
		case "pickStepped": {
			// A step only arrives while the list is open. The walk starts from
			// the clamped selection and wraps at the live list length, so the
			// list can shrink under a reader mid-token without the selection
			// pointing past its end.
			if (action.count === 0) return state;
			const from = Math.min(state.picked, action.count - 1);
			return { ...state, picked: (from + action.step + action.count) % action.count };
		}
		case "token":
			// A new token, a new list: reset the pick, and forget the dismissal
			// when no token is under the caret at all.
			return action.id === null ? { ...state, picked: 0, dismissedAt: null } : { ...state, picked: 0 };
		case "dismissed":
			return { ...state, dismissedAt: action.at };
		case "recalled":
			return { ...state, recalled: action.line };
	}
}
