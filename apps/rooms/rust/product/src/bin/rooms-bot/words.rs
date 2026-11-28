//! The wording of the log lines and errors a process test reads, present or
//! absent. Only a line a process test reads lives here. The bot writes each
//! line through its item here and the tests look for the same item's text, so
//! rewording a line cannot leave an assertion passing on text nothing writes
//! any more. A unit test reads the item its module's writer uses.

/// The start of every line the bot writes about one note.
pub fn note(operation: &str) -> String {
	format!("the direct-message open under operation {operation}")
}

/// The start of every line the bot writes about the note of one of the
/// agent's actions.
pub fn action(operation: &str) -> String {
	format!("the agent's action under operation {operation}")
}

/// The start of every line a look at a note writes about the open it sent to
/// `peer`. The serving bot writes none for a note it does not look at.
pub fn looked(operation: &str, peer: &str) -> String {
	format!("{} to {peer}", note(operation))
}

/// Ends the line for a turn whose access stopped working.
pub const HALTED: &str = "halted, because the access stopped working";
/// Starts a reply that says the bot could not answer.
pub const COULD_NOT_ANSWER: &str = "I could not answer that";
/// Says the bot's instructions file could not be read.
pub const INSTRUCTIONS_UNREADABLE: &str = "the bot's instructions file could not be read";
/// Names the write of a start's settings and link.
pub const SAVING_LINK: &str = "saving the settings and link";
/// Says a start's settings and link were saved by a retry.
pub const SAVED_ON_RETRY: &str = "saving the settings and link worked on the retry";
/// Says a step failed and will be tried again.
pub const TRYING_AGAIN: &str = "failed, trying again";
/// Says the session holds nothing for a note's open.
pub const HOLDS_NOTHING: &str = "the session holds nothing for";
/// Says a turn began.
pub const TURN_STARTED: &str = "started in conversation";
/// Says a turn ended.
pub const TURN_FINISHED: &str = "finished in conversation";
/// Says an open may have created a conversation.
pub const MAY_HAVE_OPENED: &str = "may have opened";
/// Says an open reused a conversation that was already there.
pub const REUSED_DIRECT: &str = "reused direct conversation";
/// Says a verb met a moved workspace and tries again.
pub const CONFLICT_RETRY: &str = "met a moved workspace and tries again";
/// Ends the line for an open dropped because the workspace moved.
pub const MOVED: &str = ", because the workspace moved and nothing was committed";
/// Says this access holds no receipt of a line it did not send.
pub const NO_RECEIPT_HELD: &str = "This access holds no receipt of it";
/// Says a line was sent by another access.
pub const NOT_SENT_HERE: &str = "which this access did not send";

/// Starts the line for a send the session holds no receipt of.
pub const NO_RECEIPT: &str = "the session holds no receipt for operation";
/// Starts the line for a receipt the session would not take back.
pub const RECEIPT_LEFT: &str = "the session would not take back the receipt of operation";
/// Says a posted line's receipt was refused for keeping.
pub const NOT_KEPT: &str = "the session would not keep it";
/// Ends the line for a line nobody can confirm.
pub const MOVED_ON: &str = "Moving on without sending it again";
/// The error for a call the session left unanswered past its deadline.
pub const UNANSWERED: &str = "the session did not answer in time";
/// Marks a note a look could not settle and left unsettled.
pub const DID_NOT_SETTLE: &str = "did not settle";
/// Why a look gives back an open an earlier look gave up on.
pub const GIVEN_UP: &str = "an earlier look gave it up";
/// Marks a note whose look is still waiting on the session.
pub const STILL_SETTLING: &str = "has not settled";
/// Says an agent's action committed and the bot kept what it returned.
pub const ACTION_KEPT: &str = "committed, and what it returned is kept";
/// Marks a note whose route the session kept.
pub const KEPT_ROUTE: &str = "kept its route";
/// Says a replaced line's receipt was kept by the access that holds it again.
pub const LINE_KEPT: &str = "was finished by another access and its receipt is now kept";
/// Says a replaced line's receipt was given back by the access that holds it
/// again.
pub const LINE_RELEASED: &str = "was finished by another access and its receipt is now released";

/// Says a note, a line, or a record could not be read back.
pub const COULD_NOT_BE_READ: &str = "could not be read";
/// Says the session cannot say whether a line posted.
pub const CANNOT_SAY_WHETHER: &str = "cannot say whether operation";
/// Starts the line for a look the session refused.
pub const REFUSED_LOOK: &str = "the session refused a look at operation";
/// Says a failed save will be tried again without running the agent again.
pub const SAVE_RETRIED_WITHOUT_RUNNING: &str = "trying again without running it";
/// Starts the line for a harness group a killed bot left running and a start ended.
pub const ENDED_GROUP: &str = "ended harness group";
/// Starts the line for a session command a turn runs, with its operation.
pub fn command_running(name: &str, operation: &str) -> String {
	format!("running session command {name} under operation {operation}")
}
/// Names the refusal of a session command whose first log line cannot be written.
pub const COMMAND_LOG_FAILED: &str = "writing the log before a command";
/// Ends the log's record of a session command with what it came to.
pub fn command_ran(name: &str, operation: &str, outcome: &str) -> String {
	format!("ran session command {name} under operation {operation}: {outcome}")
}
/// Says a line the session committed nothing for is sent under a new operation.
pub const SENDING_UNDER_NEW: &str = "Sending it under a new one";
/// Starts the error for a first link the session refused.
pub const LINK_NOT_ACCEPTED: &str = "the session did not accept the link";
/// Starts the refusal of a replacement link the session did not accept.
pub const REPLACEMENT_NOT_ACCEPTED: &str = "the session did not accept the replacement link";
/// Starts the refusal of a replacement whose old access could not list.
pub const OLD_UNLISTED: &str = "the old access could not list the receipts it holds";
/// The cause the stand-in gives when a fault makes the session refuse to say
/// whose receipt an operation is.
pub const ASK_REFUSED_FAULT: &str = "a fault made the ask refuse for good";
/// Starts the error for a session that refused to say whose receipt an operation is.
pub const ASK_REFUSED: &str = "the session refused to say whose receipt a sent line or open is";
/// Ends that error with the way on.
pub const START_AGAIN: &str = "then start the bot again";
/// The line the bot posts when `/reset` is the whole of what it was asked.
pub const RESET_CONFIRMED: &str = "Started a new conversation. I no longer remember what was said here before.";
/// Says the bot could not show its typing notice.
pub const COULD_NOT_SHOW_TYPING: &str = "could not show typing";
/// Says the bot could not take its typing notice down.
pub const COULD_NOT_STOP_TYPING: &str = "could not stop showing typing";
/// Says a conversation has no uncertain `--dm` open to look at again.
pub const NO_UNCERTAIN_OPEN: &str = "has no uncertain --dm open";
/// Says the log could not be written before a `--dm` open.
pub const OPENING_LOG_FAILED: &str = "writing the log before opening a direct conversation";
/// Starts the log line a turn writes before it opens a direct conversation.
pub const OPENING: &str = "is opening a direct conversation";
/// The start of the refusal for a nickname the session did not reach.
pub fn not_reached(peer: &str) -> String {
	format!("the session did not reach {peer} for --dm")
}
/// Tells a turn how to see who it can reach.
pub const RUN_WORKSPACE: &str = "Run workspace to see the people you can reach";
/// The start of every refusal for a `--dm` open the bot settles itself.
pub fn settling(peer: &str) -> String {
	format!("the bot is settling the --dm open to {peer} itself")
}
/// Says the bot's old access stopped working during a replacement.
pub const OLD_ACCESS_STOPPED: &str = "the old access stopped working";
/// Says a bot directory has no session link.
pub const NO_SESSION_LINK: &str = "has no session link yet";
/// Says a turn's verbs act only while the turn runs.
pub const ONLY_WHILE_TURN: &str = "Bot commands can run only during an active turn in this conversation";
/// Says a stored link lost its settings.
pub const CONFIG_MISSING: &str = "config.json is missing";
/// Tells an operator how to go on after a lost file.
pub const RESTORE_OR_START_FRESH: &str = "Restore the missing file from a backup, or to start fresh,";
/// Says a first start found notes an earlier link sent.
pub const OPENS_FROM_EARLIER_LINK: &str = "opens/ holds direct-message opens an earlier link sent";
/// Ends the last part of an answer cut for its length.
pub const CUT_NOTICE: &str = "\n\n[The answer was cut here because it was too long.]";
