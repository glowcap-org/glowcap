//! The peer with a running authority writer that the writer-order tests share.
use super::*;
use glowcap::Argument;
use rooms_application::server::links::Authority;

/// Run `scenario` against a peer whose authority writer is running, and stop
/// both afterward.
pub(super) async fn writer_running<F, Fut>(label: &str, scenario: F)
where
	F: FnOnce(Rc<RefCell<State>>) -> Fut,
	Fut: std::future::Future<Output = ()>,
{
	let temp = rooms_testing::scratch::Scratch::create(label);
	let config = Config::parse(
		[format!("--state={}", temp.display()), "--transport=tcp".into()],
		|_| None,
	)
	.unwrap()
	.unwrap();
	let mut peer = Peer::open(config, Rc::new(|_| {})).await.unwrap();
	let shared = peer.state.clone();
	let writer = peer.owners.authority.take().unwrap();
	let writing = tokio::task::spawn_local(writer.run(shared.clone()));
	scenario(shared.clone()).await;
	shared.borrow().authority_writer.stop();
	writing.await.unwrap();
	drop(shared);
	peer.close().await.unwrap();
}

/// Queue one authority change that answers nothing.
pub(super) fn change(
	shared: &Rc<RefCell<State>>,
	verb: &'static str,
	prepare: impl FnOnce(&State) -> Result<Option<Authority>, String> + 'static,
) -> impl std::future::Future<Output = Result<Argument, String>> {
	authority::queue::request(&shared.borrow(), verb, prepare, |_| Ok(Argument::Void))
}
