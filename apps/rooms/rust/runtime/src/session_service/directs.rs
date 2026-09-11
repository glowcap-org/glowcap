//! Compose registration, reciprocal routes and direct delivery for one session.
use super::{error::Error, Platform};
use crate::{
	archive_shares::ShareReceiver,
	direct_commands::{CommandWorker, DirectCommands},
	direct_dispatch::{DirectDispatcher, DirectWorker},
	direct_events::{DirectEvents, EventReceiver, Events},
	direct_routes::{DirectRoutes, RouteReceiver},
	directory_runtime::{handed_rooms::HandedReceiver, AcceptedDirect, DirectoryRuntime, RegistrationInbox},
	room_offers::OfferReceiver,
	session_archive::SessionArchive,
	session_commands::SessionCommands,
};
use glowcap::{Argument, Behavior, Host};
use rooms_application::text::DocumentText;
use rooms_glowcap::client::{
	direct::{publisher::Publisher, receiver},
	sources::Sources,
	Client, Error as ClientError,
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
	pub outcomes: crate::direct_dispatch::Outcomes,
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
	) -> Result<(Self, DirectWorkers<P>, Events), Error> {
		let publisher = Publisher::new(host, platform.clone()).map_err(|e| Error::runtime(e.to_string()))?;
		let routes = DirectRoutes::new();
		let (events, received) =
			DirectEvents::with_recorder(platform.clone(), entropy, archive, source).map_err(Error::runtime)?;
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
		let dispatch = self.dispatcher.close().await.map_err(Error::runtime);
		let commands = self.commands.close().await.map_err(Error::runtime);
		self.routes.close();
		let files = self.events.close_files().await.map_err(Error::runtime);
		drop(self.sources);
		Error::fold(Error::fold(dispatch, commands), files)
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
	move |context| {
		let platform = platform.clone();
		let (lines, routes, offers, handed, shares) = (
			lines.clone(),
			routes.clone(),
			offers.clone(),
			handed.clone(),
			shares.clone(),
		);
		Ok(Box::new(receiver(move |notice, session| {
			use rooms_application::direct::Notice;
			match notice {
				Notice::Message {
					text,
					attachments,
					reply,
				} => {
					let client = Client::new(session, platform.clone());
					if let Some(reply) = reply {
						routes.adopt(&context, client.clone(), reply)?;
					}
					lines
						.post(context.clone(), client.session(), text, attachments)
						.map(Argument::Reference)
				}
				Notice::Ready(reply) => {
					let client = Client::new(session, platform.clone());
					routes.adopt(&context, client, reply)?;
					Ok(Argument::Void)
				}
				Notice::Typing(on) => {
					lines.typing(context.clone(), on)?;
					Ok(Argument::Void)
				}
				Notice::OfferRoom { label, link } => offers.receive(&context, &session, label, link),
				Notice::HandRoom { label, room } => {
					handed.receive(&context, session, label, room)?;
					Ok(Argument::Void)
				}
				Notice::OfferArchive {
					directory,
					kind,
					conversation,
					link,
				} => shares.offer(&context, directory, kind, conversation, link),
				Notice::HandArchive {
					directory,
					kind,
					conversation,
					archive,
				} => shares.hand(&context, session, directory, kind, conversation, archive),
			}
		})))
	}
}
