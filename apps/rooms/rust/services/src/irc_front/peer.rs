use super::{
	client,
	config::Config,
	notice::{Notice, Report},
	transport,
};
use glowcap::{Host, Locator, PendingWork};
use rooms_application::server::irc::front;
use rooms_glowcap::client::direct::publisher::Publisher;
use rooms_platform::{HostPlatform, serving};
use std::{future::Future, rc::Rc, time::Duration};
use tokio::{net::TcpListener, sync::watch, task::JoinSet};
pub struct Ready {
	pub port: u16,
	pub directory: String,
	pub dm: String,
}
pub(super) struct Context {
	pub names: super::names::Names,
	pub inboxes: Rc<super::inboxes::Inboxes>,
	/// The posture of each client's iroh endpoint, when one is needed at all:
	/// the directory's, so a bare node id resolves through discovery and a
	/// hinted one is dialed as written.
	pub iroh: Option<glowcap::iroh::Reachability>,
	pub directory: Locator,
	pub server: String,
	pub publisher: Publisher<HostPlatform>,
	pub report: Report,
}
pub async fn run(
	config: Config,
	report: Report,
	halt: impl Future<Output = ()>,
	ready: impl FnOnce(&Ready),
) -> Result<(), String> {
	let tls = transport::tls(&config).await?;
	let host = Host::with_options(rooms_glowcap::host_options()).map_err(|e| e.to_string())?;
	let (direct, dm, runtime) = match transport::open(&config, &host).await {
		Ok(opened) => opened,
		Err(error) => {
			return crate::cleanup::combine(
				Err(error),
				host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			);
		}
	};
	let mut inboxes = None;
	let setup = async {
		let local_bind = match &config.dm {
			super::config::DirectListener::Tcp { bind, .. } => bind.as_str(),
			_ => "127.0.0.1",
		};
		let shared_inboxes = Rc::new(super::inboxes::Inboxes::open(&host, &dm, &direct, local_bind).await?);
		inboxes = Some(shared_inboxes.clone());
		let publisher = Publisher::with_limit(
			host.clone(),
			HostPlatform,
			front::CLIENTS * rooms_application::direct::publication::DEFAULT_INBOX_LIMIT,
		)
		.map_err(|e| e.to_string())?;
		let listener = TcpListener::bind((config.bind.as_str(), config.port))
			.await
			.map_err(|e| e.to_string())?;
		let port = listener.local_addr().map_err(|e| e.to_string())?.port();
		let dm_uri = glowcap::format_locator_uri(&dm).map_err(|e| e.to_string())?;
		let context = Rc::new(Context {
			names: Default::default(),
			inboxes: shared_inboxes,
			iroh: (config.directory.transport == glowcap::TRANSPORT_IROH
				|| matches!(config.dm, super::config::DirectListener::Iroh))
			.then(|| config.directory_reachability()),
			directory: config.directory,
			server: config.server,
			publisher,
			report: report.clone(),
		});
		ready(&Ready {
			port,
			directory: config.directory_text,
			dm: dm_uri,
		});
		Ok::<_, String>((listener, context))
	}
	.await;
	let mut partners = JoinSet::new();
	let mut result = match setup {
		Err(error) => Err(error),
		Ok((listener, context)) => {
			let (stop, stopping) = watch::channel(false);
			let mut clients = JoinSet::new();
			let (mut irc_retry, mut direct_retry, mut private_retry) = (
				serving::Retry::default(),
				serving::Retry::default(),
				serving::Retry::default(),
			);
			tokio::pin!(halt);
			let result = loop {
				tokio::select! {
					_ = &mut halt => break Ok(()),
					accepted = listener.accept(), if clients.len()<front::CLIENTS && irc_retry.ready() => match accepted {
						Ok((socket,_))=>{
							let (tls,context,mut stopped)=(tls.clone(),context.clone(),stopping.clone());
							clients.spawn_local(async move {
								let stream:Box<dyn client::Stream>=if let Some(tls)=tls {
									let secured=tokio::select! {
										_ = stopped.changed() => return Ok(()),
										result = tokio::time::timeout(Duration::from_secs(10),tls.accept(socket)) => result.map_err(|_|"IRC TLS handshake timed out")?.map_err(|e|e.to_string())?,
									};
									Box::new(secured)
								}else{Box::new(socket)};
								client::run(stream,context,stopped).await
							});
						}
						Err(error)=>refused(&report, &mut irc_retry, "IRC", &error),
					},
					accepted = direct.accept(), if direct_retry.ready() => match accepted {
						Ok(session)=> match context.inboxes.attaching(session) {
							Ok(None) => {},
							Ok(Some(session)) if partners.len()<serving::CONNECTION_LIMIT => {partners.spawn_local(serving::serve_partner(session));},
							Ok(Some(session)) => { if let Err(error) = session.close(PendingWork::Cancel).await { break Err(error.to_string()); } },
							Err(error) => break Err(error),
						},
						Err(error) if serving::accept_ended(&error) => break Err(error.to_string()),
						Err(error) => refused(&report, &mut direct_retry, "public inbox", &error),
					},
					accepted = context.inboxes.accept_private(), if private_retry.ready() => match accepted {
						Ok(session) => match context.inboxes.attaching(session) {
							Ok(None) => {},
							Ok(Some(session)) => { if let Err(error) = session.close(PendingWork::Cancel).await { break Err(error.to_string()); } },
							Err(error) => break Err(error),
						},
						Err(error) if serving::accept_ended(&error) => break Err(error.to_string()),
						Err(error) => refused(&report, &mut private_retry, "local inbox", &error),
					},
					_ = irc_retry.wait() => {},
					_ = direct_retry.wait() => {},
					_ = private_retry.wait() => {},
					Some(ended) = clients.join_next(), if !clients.is_empty() => {
						match ended {
							Ok(Err(error))=>report(Notice::ClientEnded(error)),
							Err(error)=>break Err(error.to_string()),
							Ok(Ok(()))=>{},
						}
					}
					Some(ended) = partners.join_next(), if !partners.is_empty() => {
						match ended {
							Ok(Err(error)) => report(Notice::InboxEnded(error.to_string())),
							Err(error) => break Err(error.to_string()),
							Ok(Ok(())) => {},
						}
					}
				}
			};
			drop(listener);
			stop.send_replace(true);
			let mut result = result;
			while let Some(ended) = clients.join_next().await {
				match ended {
					Ok(Err(error)) => report(Notice::ClientEnded(error)),
					Err(error) => result = crate::cleanup::combine(result, Err(error.to_string())),
					Ok(Ok(())) => {}
				}
			}

			result
		}
	};
	if let Some(inboxes) = inboxes {
		result = crate::cleanup::combine(result, inboxes.close().await);
	}
	result = crate::cleanup::combine(result, direct.close().await.map_err(|e| e.to_string()));
	result = crate::cleanup::combine(
		result,
		runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
	);
	while let Some(ended) = partners.join_next().await {
		match ended {
			Ok(Err(error)) => report(Notice::InboxEnded(error.to_string())),
			Err(error) => result = crate::cleanup::combine(result, Err(error.to_string())),
			Ok(Ok(())) => {}
		}
	}
	result
}

/// Each listener backs off on its own; the clients already in keep running
/// while a refused accept waits.
fn refused(report: &Report, retry: &mut serving::Retry, listener: &'static str, error: &impl std::fmt::Display) {
	report(Notice::AcceptRefused {
		listener,
		cause: error.to_string(),
	});
	retry.refused();
}
