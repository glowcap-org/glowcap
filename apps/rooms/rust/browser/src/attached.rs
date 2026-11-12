//! One production managed workspace shares a continuously driven browser Host.
//! IndexedDB owns session authority. Transports and file displays stay here.
use rooms_runtime::Error as RuntimeError;
mod connections;
mod driver;
mod file_display;
mod managed;
mod observation;
mod peers;
mod relay;
mod uploads;
mod view;
use crate::{ice, platform::Platform, transport};
use glowcap::{Host, PendingWork, Runtime};
use rooms_runtime::cleanup::{self, failed};
use std::rc::Rc;
use wasm_bindgen::prelude::*;
type Result<T> = std::result::Result<T, RuntimeError>;
#[derive(Clone)]
struct TroubleReporter {
	callback: js_sys::Function,
	stopped: Rc<std::cell::Cell<bool>>,
}
impl TroubleReporter {
	fn report(&self, source: &str, reason: &RuntimeError) {
		if self.stopped.get() {
			return;
		}
		if self
			.callback
			.call2(&JsValue::UNDEFINED, &source.into(), &js_error(reason))
			.is_err()
		{
			web_sys::console::error_1(&"Rooms trouble reporter failed".into());
		}
	}
}

struct Environment {
	runtime: Rc<Runtime>,
	managed: Option<managed::Owner>,
	incoming: peers::Peers,
	platform: Platform,
	sources: rooms_glowcap::client::sources::Sources<Platform>,
	displays: rooms_application::files::receiving::Budget,
	ice: ice::Source,
	/// The relay this browser dials through and is reached at, if its page
	/// has a Rooms server.
	front: Option<transport::WebFront>,
	managed_signaling: Rc<managed::signaling::Routes>,
	trouble: TroubleReporter,
}
impl Environment {
	async fn enliven(&self, uri: &str) -> Result<glowcap::Ref> {
		match self.runtime.host().enliven(uri).await {
			Ok(reference) => Ok(reference),
			Err(error)
				if self.front.is_none()
					&& error.cause() == glowcap::RouteFailure::TransportUnavailable.cause().with_fetch() =>
			{
				match transport::requires_front(uri) {
					Ok(true) => Err(transport::no_server()),
					Ok(false) => Err(RuntimeError::from(error)),
					Err(classification) => {
						self.trouble
							.report("Relay route classification", &RuntimeError::from(classification));
						Err(RuntimeError::from(error))
					}
				}
			}
			Err(error) => Err(RuntimeError::from(error)),
		}
	}

	async fn prepare(tab: &str) -> Result<(Platform, managed::Prepared)> {
		let platform = Platform::new().map_err(RuntimeError::platform)?;
		let prepared = managed::Prepared::open(tab, platform.clone()).await?;
		Ok((platform, prepared))
	}
	async fn open(
		platform: Platform,
		prepared: managed::Prepared,
		trouble: TroubleReporter,
		admission: rooms_application::admission::Settings,
		front: Option<transport::WebFront>,
	) -> Result<Self> {
		let host =
			Host::from_seed_with_options(prepared.seed(), rooms_glowcap::host_options()).map_err(RuntimeError::from)?;
		let managed_signaling = Rc::new(managed::signaling::Routes::default());
		let routes = managed_signaling.clone();
		let ice = match &front {
			Some(front) => ice::Source::new(front.ice()),
			None => ice::Source::stun_default().map_err(RuntimeError::platform)?,
		};
		let runtime = match transport::open(
			&host,
			front.clone(),
			move |locator, origin| routes.select(locator, origin),
			ice.clone(),
		)
		.await
		{
			Ok(runtime) => Rc::new(runtime),
			Err(error) => {
				return Err(failed(
					error.into(),
					host.close(PendingWork::Cancel).await.map_err(RuntimeError::from),
				));
			}
		};
		let mut environment = Self {
			runtime,
			managed: None,
			incoming: peers::Peers::start(),
			sources: rooms_glowcap::client::sources::Sources::new(platform.clone()),
			platform,
			displays: Default::default(),
			ice,
			front,
			managed_signaling,
			trouble,
		};
		match managed::Owner::open(&environment, prepared, admission).await {
			Ok(owner) => environment.managed = Some(owner),
			Err(error) => return Err(failed(error, environment.close().await)),
		}
		Ok(environment)
	}
	async fn close(&self) -> Result<()> {
		if let Some(owner) = &self.managed {
			owner.close().await?;
		}
		let incoming = self.incoming.close().await;
		let (ice, runtime) = tokio::join!(self.ice.close(), self.runtime.close(PendingWork::Cancel));
		cleanup::combine(
			incoming,
			cleanup::combine(ice.map_err(RuntimeError::platform), runtime.map_err(RuntimeError::from)),
		)
	}
}
fn scalar(value: js_sys::JsString, maximum: usize) -> Result<String> {
	crate::js_text::scalar(&value, maximum).map_err(RuntimeError::invalid_by)
}
fn safe_integer(value: f64) -> Result<u64> {
	if !value.is_finite() || !(0.0..=9_007_199_254_740_991.0).contains(&value) || value.fract() != 0.0 {
		Err(RuntimeError::invalid(
			"Rooms revision is outside the safe integer range",
		))
	} else {
		Ok(value as u64)
	}
}
fn js_error(error: &RuntimeError) -> JsValue {
	crate::failure::js_error(error)
}
fn rejected(error: RuntimeError) -> js_sys::Promise {
	js_sys::Promise::reject(&js_error(&error))
}

fn command_input(
	operation: js_sys::JsString,
	name: js_sys::JsString,
	arguments: js_sys::Array,
) -> Result<(String, String, Vec<String>, usize)> {
	let operation = scalar(operation, 65_536)?;
	let name = scalar(name, 128)?;
	if arguments.length() as usize > rooms_application::session::command::MAX_ARGUMENTS {
		return Err(RuntimeError::invalid("Too many Rooms command arguments"));
	}
	let mut bytes = operation.len() + name.len();
	let mut values = Vec::with_capacity(arguments.length() as usize);
	for value in arguments.iter() {
		let value = value
			.dyn_into::<js_sys::JsString>()
			.map_err(|_| RuntimeError::invalid("Rooms command arguments must be strings"))?;
		let value = scalar(value, 65_536)?;
		bytes += value.len();
		if bytes > driver::MAX_BYTES {
			return Err(RuntimeError::invalid("Rooms command exceeds the retained input budget"));
		}
		values.push(value);
	}
	Ok((operation, name, values, bytes))
}
