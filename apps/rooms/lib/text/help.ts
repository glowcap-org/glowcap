// Help, in two tiers, because two different people open it.
//
// The first tier is for somebody who was sent a link and wants to know what
// they have opened. The second is the glossary, for a reader matching a word
// on this screen against a word a server printed.
//
// The first tier explains Rooms the way you would to a friend, by saying what
// it is like. Rooms is IRC with links instead of accounts, and anybody who has
// used IRC already knows most of it. Rooms also bridges real IRC, so the
// comparison is literal.
//
// This tier is not a pitch. Three failures to watch for: copy that sells ("a
// link is the permission"), copy that is false ("nothing to forget", when
// losing the link is how you lose your rooms), and copy that is technically
// true and leaves the wrong picture ("runs in this page, not on a server",
// when there is a server and room messages go through it).

export const helpTitle = "Help";
export const helpPartsCatalog = "the parts catalog";

/** The three tabs. One word each, because they share one row on a phone. */
export const helpTabAbout = "About";
export const helpTabWriting = "Writing";
export const helpTabGlossary = "Glossary";

/** A pointer to something a reader may already know. Rooms bridges real IRC,
 * so the comparison is to software a reader might have used. */
type HelpLink = { text: string; href: string };

/** A sentence with links in it, in the pieces the component sets. A string is
 * text and a link is drawn as one. */
export type LinkedText = readonly (string | HelpLink)[];

/** The one-liner. Everything under it is a detail of this sentence, and a
 * reader who has used IRC can stop here. The contrast with IRC is a room that
 * is a link. */
export const helpAboutLead: LinkedText = [
	"Rooms is a chat app. It's inspired by ",
	{ text: "IRC", href: "https://en.wikipedia.org/wiki/Internet_Relay_Chat" },
	", and even works with it. The difference is underneath: it's built on ",
	{ text: "OCapN", href: "https://ocapn.org" },
	", so a room can be a link, and whoever holds the link is in.",
];

export const helpAbout: readonly { title: string; said: string; link?: HelpLink }[] = [
	{
		title: "Getting in",
		said:
			"A public room is a name on a server: type it and you're there, and if no room has that name yet, that makes one. A private room is a link someone sends you. Either way there's no account and no password. Keep the link. If you lose it, ask them for another. Anyone you send it to can get in too.",
	},
	{
		title: "The server",
		said:
			"There's a server hosting the rooms, like an IRC server. What you type in a room goes through it. You just don't have an account on it.",
	},
	{
		title: "Direct messages",
		said:
			"The server doesn't read messages you send to one person. Depending on your settings they go straight to them, or encrypted through the server's relay. Room messages it does read.",
	},
	{
		title: "Names",
		said:
			"Any name works, nothing checks it. Two people can't use the same one on a server at the same time. It isn't reserved for you either. If you leave, someone else can take it.",
	},
	{
		title: "Saved messages",
		said:
			"Whether messages are saved is up to whoever runs the server. If they aren't, they're gone when it stops.",
	},
	{
		title: "The wait when it opens",
		said: "Part of Rooms runs in this tab, and that takes a second to start.",
	},
];

/** The credit, last on the About tab, for the reader who wants to know what
 * Rooms is made from or to read its code. */
export const helpAboutCredit: LinkedText = [
	"Rooms is built with ",
	{ text: "glowcap", href: "https://glowcap.org/" },
	", an OCapN library. Both are open source, and the code is on ",
	{ text: "GitHub", href: "https://github.com/glowcap-org/glowcap" },
	".",
];

/** The protocol's own words, for the reader matching them against a server's
 * output. They stay exact, since an approximate definition is worse than none
 * for the person who needs this tier. */
export const helpGlossaryLead =
	"Rooms is built on OCapN, and a server prints these words. You don't need any of them to use Rooms.";

export const helpDirectory = "Directory";
/** The link between the two tiers. A guest reads "server" and an operator
 * reads "directory" on the Operations pages, and this entry says they are the
 * same thing. */
export const helpDirectorySaid =
	"What the rest of Rooms calls the server. The object this page starts from: rooms live on it, and fetching it is how a peer arrives. A session can hold more than one, which is why the Operations pages name them.";

export const helpLocator = "Locator";
export const helpLocatorSaid =
	"A peer address: hostname:port for plain TCP, or an ocapn:// URI for other transports. A sturdyref adds an object's unguessable name.";

export const helpCapability = "Capability";
export const helpCapabilitySaid = "A reference whose possession is permission, without a separate account check.";

export const helpSwiss = "Swiss number";
/** Split around the "secret" control, so the sentence comes in the two halves
 * the component sets around it. */
export const helpSwissBefore = "A";
export const helpSwissSecret = "secret";
export const helpSwissAfter =
	", unguessable name a peer will look up for you. Each operations capability is published under one when the server starts with one of those flags (--diagnostics, --admin-listeners, --operator, or --peering). That is what the server prints. A durable room entry link is named by one too.";

export const helpSturdyref = "Sturdyref";
export const helpSturdyrefSaid =
	"A locator and swiss number kept for later. Redeeming it asks that peer to honor the name. A room entry link is one.";

export const helpKitchenBack = "Back to the glossary";
export const helpCopyBuild = "Copy build";
