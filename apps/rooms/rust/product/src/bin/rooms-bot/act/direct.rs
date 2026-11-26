//! `--dm <nickname>`: the direct conversation a `say` or `send` posts to. It
//! reaches any member the session's own `View::reach_direct` accepts in the
//! directory of the turn's conversation, as a person on the same access
//! reaches them: an unregistered nickname and the bot's own are refused. The
//! session decides which conversation with that registration the post goes
//! to (`View::reach_direct` and `View::introduce`). The bot's log names the
//! peer and the conversation before every post `--dm` reaches, and says
//! "opened" only once the open committed.
//!
//! An open is noted (`opens::note`) before it is sent, so looking again at an
//! uncertain open from this conversation sends that same one, and its note
//! goes once it settles. One still uncertain when the turn ends is settled by
//! the serving bot (`opens::settle`), and a `--dm` to a peer a live note names
//! is refused until it settles.
use super::{Step, Turn, failure, verbs::resend};
use crate::bot::{
	error::Error,
	fault::{self, Fail},
	identity,
	opens::{self, Open},
	request::Request,
	rooms::{Base, ConversationId, captp::Live},
	store,
	words::{self, MOVED},
};
use rooms_application::{
	content::session::workspace::Conversation,
	failure::{FailureCode, Retry},
	room::inbox::same_nick,
};
use rooms_services::session::{
	attached::{Error as ViewError, First, GiveBack, Introduction, Opened, Reach},
	control::Failure,
};
use serde_json::{Value, json};

/// The flags `--dm` reads beside a verb's own.
pub const DM: &str = "dm";
/// What `--dm` asks for, read before the turn spends a place.
pub struct Ask {
	peer: String,
	/// The operation and base of an earlier open whose outcome was uncertain.
	again: Option<(String, u64)>,
}

impl Ask {
	/// The nickname `--dm` named.
	pub fn peer(&self) -> &str {
		&self.peer
	}

	/// Whether this looks again at an earlier open by its operation and base.
	pub fn looks_again(&self) -> bool {
		self.again.is_some()
	}
}

/// The `--dm` a request names, or none. `--conversation` names another
/// place, so the two are refused together, and `--operation` with `--base`
/// only looks again at an uncertain open.
pub fn ask(request: &Request) -> Result<Option<Ask>, Error> {
	let again = resend(request)?;
	let Some(peer) = request.single(DM)? else {
		return match again {
			Some(_) => Err(Error::Usage(
				"--operation and --base look again at an uncertain --dm open, so they need --dm".into(),
			)),
			None => Ok(None),
		};
	};
	if request.single("conversation")?.is_some() {
		return Err(Error::Usage(
			"--dm and --conversation each name where to post. Choose one".into(),
		));
	}
	Ok(Some(Ask {
		peer: peer.to_owned(),
		again,
	}))
}

/// Whether the turn's own conversation is a direct one with `asked`.
fn is_own_peer(row: &Conversation, asked: &str) -> bool {
	match row {
		Conversation::Direct(row) => row.peer.text().as_str().is_some_and(|nick| same_nick(nick, asked)),
		Conversation::Room(_) => false,
	}
}

/// The direct conversation `ask` reaches, and the open that made it, or null
/// when an open conversation was reused. Every failure is the open's, and
/// says so, because nothing was posted yet.
pub async fn reach(live: &Live, turn: &Turn, ask: &Ask) -> Result<(String, Value), Error> {
	open_or_reuse(live, turn, ask).await.map_err(failure::opening)
}

/// What the turn's conversation and the bot directory give every step of a
/// reach.
struct DirectReach<'a> {
	live: &'a Live,
	turn: &'a Turn,
	ask: &'a Ask,
	root: std::path::PathBuf,
	log: store::Log,
	turn_conversation: ConversationId,
}

/// An open to send: its operation, base, and introduction.
struct OpenAt {
	operation: String,
	base: u64,
	introduction: Introduction,
}

/// Where a reach ends: a conversation to post to, or an open to send.
enum Route {
	Use(String),
	/// A new open, whose first call sending nothing proves it never committed.
	First(OpenAt),
	/// A look again at an uncertain open, which an earlier call under its
	/// operation may have committed.
	Again(OpenAt),
}

async fn open_or_reuse(live: &Live, turn: &Turn, ask: &Ask) -> Result<(String, Value), Error> {
	let root = store::directory(&turn.bot)?;
	let direct = DirectReach {
		live,
		turn,
		ask,
		log: turn.journal()?,
		root,
		turn_conversation: ConversationId::new(turn.conversation.as_str()),
	};
	let route = turn
		.budget
		.within(Step::Open, direct.route())
		.await
		.ok_or_else(failure::nothing_sent)??;
	match route {
		Route::Use(conversation) => Ok((conversation, Value::Null)),
		Route::First(open) => turn
			.budget
			.within(Step::Open, direct.send_first(&open))
			.await
			.ok_or_else(failure::open_spent)?,
		Route::Again(open) => turn
			.budget
			.within(Step::Open, direct.send_again(&open))
			.await
			.ok_or_else(failure::open_spent)?,
	}
}

impl DirectReach<'_> {
	async fn route(&self) -> Result<Route, Error> {
		let (turn, ask) = (self.turn, self.ask);
		let snapshot = self.live.view.snapshot().await.map_err(|cause| failure::call(&cause))?;
		let row = snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(turn.conversation.as_str()))
			.ok_or_else(|| {
				Error::Usage(format!(
					"conversation {} is no longer in the session, so --dm has no directory to find {} in",
					turn.conversation, ask.peer
				))
			})?;
		let directory = match row {
			Conversation::Room(row) => row.directory.text(),
			Conversation::Direct(row) => row.directory.text(),
		};
		let directory = directory
			.as_str()
			.ok_or(Error::Usage("the turn's conversation names no directory".into()))?;
		Ok(match &ask.again {
			Some((operation, base)) => self.again(operation, *base)?,
			// The turn's own conversation is the address, so a nickname another
			// member took since cannot redirect the post.
			None if is_own_peer(row, &ask.peer) => Route::Use(turn.conversation.clone()),
			None => self.introduce(directory).await?,
		})
	}

	fn sending<'a>(&'a self, open: &'a OpenAt) -> Sending<'a> {
		Sending { direct: self, open }
	}

	async fn send_first(&self, open: &OpenAt) -> Result<(String, Value), Error> {
		let sending = self.sending(open);
		let OpenAt {
			operation,
			base,
			introduction,
		} = open;
		let sent = match self
			.live
			.view
			.introduce_first(operation, Some(*base), introduction)
			.await
		{
			Ok(First::Sent(opened)) => Ok(opened),
			// This is the operation's first call and it sent nothing, so the
			// note goes and the serving loop never sends an open the agent was
			// told failed, unless the note cannot be removed, which `dropped`
			// says.
			Ok(First::Unsent(cause)) => {
				return sending.dropped("did not open", ", because nothing was sent", failure::call(&cause));
			}
			Err(cause) => Err(cause),
		};
		sending.finish(sent)
	}

	async fn send_again(&self, open: &OpenAt) -> Result<(String, Value), Error> {
		let OpenAt {
			operation,
			base,
			introduction,
		} = open;
		// A look again is never proof of an unsent open: an earlier call under
		// the operation may have committed.
		let sent = self.live.view.introduce(operation, Some(*base), introduction).await;
		self.sending(open).finish(sent)
	}

	/// Look again at the uncertain open `--operation` and `--base` name.
	fn again(&self, operation: &str, base: u64) -> Result<Route, Error> {
		let (turn, ask) = (self.turn, self.ask);
		let noted = opens::noted(&self.root, operation)?
			.filter(|noted| {
				noted.conversation == self.turn_conversation
					&& same_nick(&noted.introduction.peer, &ask.peer)
					&& noted.base == Base(base)
			})
			.ok_or_else(|| {
				Error::Usage(format!(
					"this conversation {} to {} under operation {operation} at base {base}: run the verb without --operation and --base",
					words::NO_UNCERTAIN_OPEN,
					ask.peer
				))
			})?;
		// A note belongs to the turn that wrote it until that turn ends, so no
		// other turn looks at it: the serving bot settles it then.
		if noted.turn != turn.id {
			return Err(Error::Usage(format!(
				"{}, so do not look at it again: a plain --dm will use the conversation once it exists",
				words::settling(&ask.peer)
			)));
		}
		opening_line(&self.log, turn, &noted.introduction.peer, operation)?;
		Ok(Route::Again(OpenAt {
			operation: operation.to_owned(),
			base,
			introduction: noted.introduction,
		}))
	}

	/// Reach the peer in `directory`: reuse an open conversation, or note a
	/// new open before it is sent.
	async fn introduce(&self, directory: &str) -> Result<Route, Error> {
		let (live, turn, ask) = (self.live, self.turn, self.ask);
		match live.view.reach_direct(directory, &ask.peer).await {
			Ok(Reach::Open(conversation)) => {
				turn.log(
					&self.log,
					&format!("{} {conversation} with {}", words::REUSED_DIRECT, ask.peer),
				);
				Ok(Route::Use(conversation))
			}
			Ok(Reach::Introduce(introduction)) => {
				turn.open()?;
				let operation = identity::new_action(&self.root)?;
				let base = live.view.revision().await.map_err(|cause| failure::call(&cause))?;
				// The log line comes first, so a refusal to write it leaves no
				// note to send.
				opening_line(&self.log, turn, &introduction.peer, &operation)?;
				let noted = Open {
					base: Base(base),
					introduction,
					conversation: self.turn_conversation.clone(),
					turn: turn.id,
				};
				if let Err(error) = opens::note(&self.root, &operation, &noted) {
					turn.log(
						&self.log,
						&format!(
							"did not open a direct conversation with {} under operation {operation}: {error}",
							noted.introduction.peer
						),
					);
					return Err(error);
				}
				Ok(Route::First(OpenAt {
					operation,
					base,
					introduction: noted.introduction,
				}))
			}
			Err(ViewError::Peer(cause)) if cause.failure_code() == Some(FailureCode::PeerOffline) => {
				Err(failure::refused(&Failure::new(
					FailureCode::PeerOffline.wire(),
					Retry::AfterStateChange,
					format!("{}: {cause}. {}", words::not_reached(&ask.peer), words::RUN_WORKSPACE),
				)))
			}
			Err(cause) => Err(failure::call(&cause)),
		}
	}
}

/// The open is an effect, so it is refused unless its first line is written.
fn opening_line(log: &store::Log, turn: &Turn, peer: &str, operation: &str) -> Result<(), Error> {
	turn.try_log(
		log,
		&format!(
			"{} with {peer} under operation {operation}, which may have opened if no outcome line follows",
			words::OPENING
		),
	)
	.map_err(Error::io(words::OPENING_LOG_FAILED))
}

/// The open's own operation and what it needs to log and settle its note.
struct Sending<'a> {
	direct: &'a DirectReach<'a>,
	open: &'a OpenAt,
}

/// What a failed open says of whether it committed.
enum Applied {
	/// It committed nothing, for the reason named, so its note goes.
	Nothing(&'static str),
	/// A dispatch the call could not rule out may have committed, so the note
	/// stays for the loop to settle.
	Unknown,
}

/// The one classification of a failed open. A conflict is also the class the
/// verb retries on (`failure::is_conflict`), so an answer that retries drops
/// its note and one that keeps its note never retries.
fn applied(cause: &ViewError) -> Applied {
	match cause {
		ViewError::Conflict => Applied::Nothing(MOVED),
		ViewError::Unkeepable { .. } => Applied::Nothing(", because it was refused before it was sent"),
		ViewError::Unopened {
			receipt: GiveBack::Released,
			..
		} => Applied::Nothing(", because its route could not be kept and the session gave its receipt back"),
		ViewError::Uncertain { .. }
		| ViewError::Unopened {
			receipt: GiveBack::Running | GiveBack::Held | GiveBack::Failed(_),
			..
		}
		| ViewError::Refused
		| ViewError::Revoked
		| ViewError::Paused
		| ViewError::Unreachable(_)
		| ViewError::Peer(_)
		| ViewError::Stale
		| ViewError::Unkept { .. }
		| ViewError::Forfeited { .. }
		| ViewError::Input(_)
		| ViewError::Malformed(_)
		| ViewError::Budget
		| ViewError::Exists(_)
		| ViewError::Io(_) => Applied::Unknown,
	}
}

impl Sending<'_> {
	fn line(&self, what: &str, landed: &str) {
		self.direct.turn.log(
			&self.direct.log,
			&format!(
				"{what} a direct conversation with {} under operation {}{landed}",
				self.open.introduction.peer, self.open.operation
			),
		);
	}

	/// Drop the note of an open that settled, and say whether it went. A note
	/// that stays is the serving loop's to settle once the turn ends, so the
	/// open's own outcome is still what the verb prints, marked.
	fn settled(&self) -> bool {
		let removed = if fault::fails(Fail::DropNote) {
			Err(Error::io("removing a settled note")(std::io::Error::other(
				"a fault made the removal fail",
			)))
		} else {
			opens::forget(&self.direct.root, &self.open.operation)
		};
		let Err(error) = removed else {
			return true;
		};
		// tolerant: a note left behind is settled by the serving loop once the
		// turn ends, and the verb's line says so (`settling`).
		self.direct.turn.log(
			&self.direct.log,
			&format!(
				"could not drop the note of the open to {} under operation {}: {error}",
				self.open.introduction.peer, self.open.operation
			),
		);
		false
	}

	/// Log an open that committed nothing, drop its note, and fail with `cause`.
	/// A note that stays may still be sent by the serving loop, so the failure
	/// says the bot settles it.
	fn dropped(&self, what: &str, why: &str, cause: Error) -> Result<(String, Value), Error> {
		self.line(what, why);
		Err(if self.settled() {
			cause
		} else {
			failure::marked(cause, "settling", json!("bot"))
		})
	}

	/// Log what the open did before anything posts through it, and drop its
	/// note once it settles.
	fn finish(&self, sent: Result<Opened, ViewError>) -> Result<(String, Value), Error> {
		match sent {
			Ok(Opened::Opened { conversation, sent }) => {
				self.line("opened", &format!(", as conversation {conversation}"));
				let mut opened = json!({"operation": sent.operation, "base": sent.base});
				if !self.settled() {
					opened["settling"] = json!("bot");
				}
				Ok((conversation, opened))
			}
			Ok(Opened::Reused { conversation, .. }) => {
				self.line(
					"reused",
					&format!(", and another open had made it, as conversation {conversation}"),
				);
				// A note that stays is looked at again and finds the same open.
				self.settled();
				Ok((conversation, Value::Null))
			}
			Ok(Opened::Unapplied(sent)) => self.dropped(
				"did not open",
				MOVED,
				failure::with_operation(failure::unapplied(sent.status.wire()), &self.open.operation),
			),
			Ok(Opened::Uncertain(sent)) => {
				self.line(words::MAY_HAVE_OPENED, "");
				Err(failure::with_operation(failure::unsettled(&sent), &self.open.operation))
			}
			Err(cause) => match applied(&cause) {
				Applied::Nothing(why) => self.dropped("did not open", why, failure::call(&cause)),
				Applied::Unknown => {
					self.line(words::MAY_HAVE_OPENED, "");
					Err(failure::with_operation(failure::call(&cause), &self.open.operation))
				}
			},
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	/// An answer that keeps its note is never the class the verb retries on, so
	/// a retry never sends beside a note the loop has yet to settle.
	#[test]
	fn an_answer_that_keeps_its_note_never_retries() {
		for cause in [
			ViewError::Conflict,
			ViewError::Refused,
			ViewError::Paused,
			ViewError::Stale,
			ViewError::Budget,
		] {
			let keeps = matches!(applied(&cause), Applied::Unknown);
			assert!(
				!(keeps && failure::is_conflict(&failure::call(&cause))),
				"{cause:?} keeps its note and retries"
			);
		}
		assert!(matches!(applied(&ViewError::Conflict), Applied::Nothing(_)));
	}

	fn asked(named: &str) -> Result<Option<Ask>, Error> {
		ask(&Request::parse(&format!(
			r#"{{"verb":"say","state":"","named":{named},"arguments":[]}}"#
		))
		.unwrap())
	}

	#[test]
	fn dm_names_one_place_and_a_look_again_needs_its_operation_and_base_and_dm() {
		assert!(asked(r#"{"text":["hi"]}"#).unwrap().is_none());
		let first = asked(r#"{"dm":["ana"]}"#).unwrap().unwrap();
		assert_eq!((first.peer.as_str(), first.again), ("ana", None));
		let again = asked(r#"{"dm":["ana"],"operation":["op"],"base":["7"]}"#)
			.unwrap()
			.unwrap();
		assert_eq!(again.again, Some(("op".to_owned(), 7)));
		for refused in [
			r#"{"dm":["ana"],"conversation":["room"]}"#,
			r#"{"operation":["op"],"base":["7"]}"#,
			r#"{"dm":["ana"],"operation":["op"]}"#,
			r#"{"dm":["ana"],"base":["7"]}"#,
			r#"{"dm":["ana"],"operation":["op"],"base":["seven"]}"#,
		] {
			assert!(matches!(asked(refused), Err(Error::Usage(_))), "{refused}");
		}
	}
}
