//! Compose registration, reciprocal routes and direct delivery for one session.
use super::{
	Platform,
	error::Error,
	notice::{Notice, Report},
};
use crate::{
	archive::session::SessionArchive,
	archive::shares::ShareReceiver,
	direct::commands::{CommandWorker, DirectCommands},
	direct::dispatch::{DirectDispatcher, DirectWorker},
	direct::events::{DirectEvents, EventReceiver, Events},
	direct::routes::{DirectRoutes, RouteReceiver},
	directories::runtime::{AcceptedDirect, DirectoryRuntime, RegistrationInbox, handed_rooms::HandedReceiver},
	rooms::offers::OfferReceiver,
	session::commands::SessionCommands,
};
use glowcap::{Argument, Behavior, Host};
use rooms_application::text::DocumentText;
use rooms_glowcap::client::{
	Client, Error as ClientError,
	direct::{publisher::Publisher, receiver},
	sources::Sources,
};
use std::rc::Rc;

pub struct DirectGraph<P: Platform> {
	pub routes: DirectRoutes<P>,
	pub commands: DirectCommands,
	pub dispatcher: DirectDispatcher<P>,
	pub events: DirectEvents<P>,
	pub sources: Rc<Sources<P>>,
}

/// The tasks the graph needs driven, and the dispatch outcome stream the
/// peer drains: every route opening is awaited by the command that asked for
/// it, so the stream has no consumer of its own.
pub struct DirectWorkers<P: Platform> {
	pub dispatch: DirectWorker<P>,
	pub commands: CommandWorker<P>,
	pub outcomes: crate::direct::dispatch::Outcomes,
}

impl<P: Platform> DirectGraph<P> {
	#[allow(clippy::too_many_arguments)]
	pub fn open(
		host: Host,
		platform: P,
		entropy: &mut impl crate::entropy::Entropy,
		directories: DirectoryRuntime<P>,
		inbox: RegistrationInbox,
		commands: SessionCommands,
		archive: Rc<SessionArchive<P>>,
		source: DocumentText,
		offers: OfferReceiver<P>,
		handed: HandedReceiver<P>,
		shares: ShareReceiver,
		report: Report,
	) -> Result<(Self, DirectWorkers<P>, Events), Error> {
		let publisher = Publisher::new(host, platform.clone()).map_err(Error::peer)?;
		let routes = DirectRoutes::new();
		let (events, received) = DirectEvents::with_recorder(platform.clone(), entropy, archive, source)?;
		let sources = Rc::new(Sources::new(platform.clone()));
		let (direct_commands, command_worker) = DirectCommands::new(
			platform.clone(),
			commands,
			routes.receiver(),
			events.receiver(),
			sources.clone(),
		);
		let (dispatcher, dispatch_worker, outcomes) = DirectDispatcher::new(
			directories,
			inbox,
			publisher,
			routes.receiver(),
			Rc::new(move |cause| report(Notice::DirectCleanupFailed { cause })),
			factory(platform, events.receiver(), routes.receiver(), offers, handed, shares),
		);
		Ok((
			Self {
				routes,
				commands: direct_commands,
				dispatcher,
				events,
				sources,
			},
			DirectWorkers::<P> {
				dispatch: dispatch_worker,
				commands: command_worker,
				outcomes,
			},
			received,
		))
	}
	pub async fn close(mut self) -> Result<(), Error> {
		let dispatch = self.dispatcher.close().await;
		let commands = self.commands.close().await;
		self.routes.close();
		let files = self.events.close_files().await;
		drop(self.sources);
		Error::fold(Error::fold(dispatch, commands), files)
	}
}

/// Everything one accepted direct connection delivers into. The arms it owns
/// all answer with a classed failure, and [`Inbox::deliver`] is the single
/// place that becomes the refusal sentence the calling peer reads.
struct Inbox<P: Platform> {
	platform: P,
	lines: EventReceiver<P>,
	routes: RouteReceiver<P>,
	offers: OfferReceiver<P>,
	handed: HandedReceiver<P>,
	shares: ShareReceiver,
}

impl<P: Platform> Clone for Inbox<P> {
	fn clone(&self) -> Self {
		Self {
			platform: self.platform.clone(),
			lines: self.lines.clone(),
			routes: self.routes.clone(),
			offers: self.offers.clone(),
			handed: self.handed.clone(),
			shares: self.shares.clone(),
		}
	}
}

impl<P: Platform> Inbox<P> {
	fn deliver(
		&self,
		context: &AcceptedDirect,
		notice: rooms_application::direct::Notice<'_, glowcap::Ref>,
		session: glowcap::Session,
	) -> Result<Argument, Error> {
		use rooms_application::direct::Notice;
		match notice {
			Notice::Message {
				text,
				attachments,
				reply,
				previews,
			} => {
				let client = Client::new(session, self.platform.clone());
				if let Some(reply) = reply {
					self.routes.adopt(context, client.clone(), reply)?;
				}
				self.lines
					.post_with_previews(context.clone(), client.session(), text, previews, attachments)
					.map(Argument::Reference)
			}
			Notice::Ready(reply) => {
				let client = Client::new(session, self.platform.clone());
				self.routes.adopt(context, client, reply)?;
				Ok(Argument::Void)
			}
			Notice::Typing(on) => {
				self.lines.typing(context.clone(), on)?;
				Ok(Argument::Void)
			}
			Notice::OfferRoom { label, link } => self.offers.receive(context, &session, label, link),
			Notice::HandRoom { label, room } => {
				self.handed.receive(context, session, label, room)?;
				Ok(Argument::Void)
			}
			Notice::OfferArchive {
				directory,
				kind,
				conversation,
				link,
			} => self.shares.offer(context, directory, kind, conversation, link),
			Notice::HandArchive {
				directory,
				kind,
				conversation,
				archive,
			} => self
				.shares
				.hand(context, session, directory, kind, conversation, archive),
		}
	}
}

fn factory<P: Platform>(
	platform: P,
	lines: EventReceiver<P>,
	routes: RouteReceiver<P>,
	offers: OfferReceiver<P>,
	handed: HandedReceiver<P>,
	shares: ShareReceiver,
) -> impl FnMut(AcceptedDirect) -> Result<Behavior, ClientError> {
	let inbox = Inbox {
		platform,
		lines,
		routes,
		offers,
		handed,
		shares,
	};
	move |context| {
		let inbox = inbox.clone();
		Ok(Box::new(receiver(move |notice, session| {
			inbox.deliver(&context, notice, session).map_err(Error::into_refusal)
		})))
	}
}
