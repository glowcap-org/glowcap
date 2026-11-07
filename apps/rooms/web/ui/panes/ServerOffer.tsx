// The question a link that offers a Rooms server asks before anything opens.
// The server is fixed when the session opens, and a link alone never changes it: the
// reader answers here, once, and the link's offer is gone from the address
// either way.

import { useState } from "react";
import { Confirm } from "../Confirm.tsx";
import { Icon, Wordmark } from "../icons.tsx";
import { serverOfferCommit, serverOfferKeep, serverOfferSay, serverOfferTitle } from "../../../lib/text/settings.ts";

/** `local` says the server is on the person's own computer or network while
 * this page is not, so the browser may ask before the page reaches it. */
export function ServerOffer(
	{ host, local, onAnswer }: { host: string; local: boolean; onAnswer: (use: boolean) => void },
) {
	// The session opens after the answer. Until it does, the question stays on
	// screen without taking a second one.
	const [answered, setAnswered] = useState(false);
	const answer = (use: boolean) => {
		if (answered) return;
		setAnswered(true);
		onAnswer(use);
	};
	return (
		<main className="session-setup card-plane" id="serverOffer">
			<div className="session-setup-inner">
				<header className="session-setup-brand brand-lockup">
					<Icon name="mark" size={56} />
					<Wordmark />
				</header>
				<div className="session-setup-heading">
					<h1>{serverOfferTitle}</h1>
				</div>
				<Confirm
					label={serverOfferTitle}
					say={serverOfferSay(host, local)}
					keep={serverOfferKeep}
					commit={serverOfferCommit}
					tone="primary"
					busy={answered}
					keepId="serverOfferKeep"
					commitId="serverOfferUse"
					onKeep={() => answer(false)}
					onCommit={() => answer(true)}
				/>
			</div>
		</main>
	);
}
