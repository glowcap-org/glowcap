//! Private mutations serialize at the root writer without cached authority.
use super::*;

/// Serializes private root mutations, including their shared receipt sequences.
/// It holds no cached revision or content. Loam remains the authority.
pub(in crate::session::managed) struct Writer {
	pub(in crate::session::managed) host: Host,
	root: RefCell<Option<(Ref, Ref)>>,
	lock: Mutex<()>,
	pub(in crate::session::managed) trouble: RefCell<Option<Box<ExecutionReporter>>>,
}
impl Writer {
	pub(in crate::session::managed) fn report(&self, scope: &str, error: &glowcap::Error) {
		if let Some(report) = self.trouble.borrow().as_ref() {
			report(scope, error);
		}
	}
	pub fn new(host: Host) -> Self {
		Self {
			host,
			root: RefCell::new(None),
			lock: Mutex::new(()),
			trouble: RefCell::new(None),
		}
	}
	pub fn bind(&self, root: Ref, control: Ref) -> Result<()> {
		let mut held = self.root.borrow_mut();
		if held.is_some() {
			return Err(loam::refusal("session root is already bound"));
		}
		*held = Some((root, control));
		Ok(())
	}
	pub fn root(&self) -> Result<Ref> {
		self.root
			.borrow()
			.as_ref()
			.map(|(root, _)| root.clone())
			.ok_or_else(|| loam::refusal("session root is not bound"))
	}
	pub fn root_control(&self) -> Result<Ref> {
		self.root
			.borrow()
			.as_ref()
			.map(|(_, control)| control.clone())
			.ok_or_else(|| loam::refusal("session root is not bound"))
	}
	pub(in crate::session::managed) async fn mutation_guard(&self) -> tokio::sync::MutexGuard<'_, ()> {
		self.lock.lock().await
	}
	pub async fn mutate(&self, verb: &str, args: &[Argument]) -> Result<Argument> {
		let _serial = self.lock.lock().await;
		let root = self.root()?;
		let sequence = self.host.send(&root, "mutation-sequence", &[]).await?;
		let mut request = Vec::with_capacity(args.len() + 2);
		request.push(sequence);
		request.push(Argument::String(verb.into()));
		request.extend_from_slice(args);
		self.host.send(&root, "mutate", &request).await
	}
	/// The application receipt owns exact settlement replay. It needs no
	/// second sequenced receipt over its newly returned foreign capabilities.
	pub async fn idempotent(&self, verb: &str, args: &[Argument]) -> Result<Argument> {
		self.idempotent_through(&self.root()?, verb, args).await
	}
	pub async fn idempotent_through(&self, source: &Ref, verb: &str, args: &[Argument]) -> Result<Argument> {
		let _serial = self.lock.lock().await;
		self.host.send(source, verb, args).await
	}
	pub async fn derive(&self, terms: PolicyValue, depth: u16, powers: ControlPowers) -> Result<(Ref, Ref)> {
		let _serial = self.lock.lock().await;
		let root = self.root()?;
		let sequence = self.host.send(&root, "derivation-sequence", &[]).await?;
		let sequence = sequence
			.as_i64()
			.and_then(|value| u32::try_from(value).ok())
			.ok_or_else(|| loam::refusal("invalid root mutation sequence"))?;
		let result = self
			.host
			.send(
				&root,
				"derive-managed",
				&terms.managed_derive_arguments(sequence, Scope::Object, depth, powers),
			)
			.await?;
		let Some([access, control]) = result.as_list() else {
			return Err(loam::refusal("invalid managed derivation result"));
		};
		Ok((
			Ref::try_from(access).map_err(|_| loam::refusal("use capability required"))?,
			Ref::try_from(control).map_err(|_| loam::refusal("control capability required"))?,
		))
	}
}
