// The join card's offer, while connecting a directory to a session with no home
// directory, to make that directory home. It is checked by default, because a
// session's first directory is the one a blank address should mean.

import { Checkbox } from "../Checkbox.tsx";
import { joinMakeHome } from "../../../lib/text/join.ts";

/** The form field that carries the choice. */
export const MAKE_HOME_FIELD = "makeHome";

export function MakeHomeChoice() {
	return (
		<label className="check-row">
			<Checkbox id="makeHome" name={MAKE_HOME_FIELD} defaultChecked />
			<span>{joinMakeHome}</span>
		</label>
	);
}
