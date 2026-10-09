//! One production managed workspace shares a continuously driven browser Host.
//! IndexedDB owns session authority; transports and file displays stay here.
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
use rooms_runtime::cleanup::combine as retain;
use std::rc::Rc;
use wasm_bindgen::prelude::*;
type Result<T> = std::result::Result<T, String>;
#[derive(Clone)]
struct TroubleReporter {
	callback: js_sys::Function,
	stopped: Rc<std::cell::Cell<bool>>,
}
impl TroubleReporter {
	fn report(&self, source: &str, reason: &str) {
		if self.stopped.get() {
			return;
		}
		if self
			.callback
			.call2(&JsValue::UNDEFINED, &source.into(), &reason.into())
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
	managed_signaling: Rc<managed::signaling::Routes>,
	trouble: TroubleReporter,
}
impl Environment {
	async fn prepare(tab: &str) -> Result<(Platform, managed::Prepared)> {
		let platform = Platform::new().map_err(|error| error.to_string())?;
		let prepared = managed::Prepared::open(tab, platform.clone()).await?;
		Ok((platform, prepared))
	}
	async fn open(platform: Platform, prepared: managed::Prepared, trouble: TroubleReporter) -> Result<Self> {
		let host = Host::from_seed_with_options(prepared.seed(), rooms_glowcap::host_options())
			.map_err(|error| error.to_string())?;
		let managed_signaling = Rc::new(managed::signaling::Routes::default());
		let routes = managed_signaling.clone();
		let front = transport::WebFront::deployment().map_err(|error| error.to_string())?;
		let ice = ice::Source::deployment();
		let runtime = match transport::open(
			&host,
			front,
			move |locator, origin| routes.select(locator, origin),
			ice.clone(),
		)
		.await
		{
			Ok(runtime) => Rc::new(runtime),
			Err(error) => {
				return Err(retain(
					Err(error.to_string()),
					host.close(PendingWork::Cancel).await.map_err(|error| error.to_string()),
				)
				.unwrap_err());
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
			managed_signaling,
			trouble,
		};
		match managed::Owner::open(&environment, prepared).await {
			Ok(owner) => environment.managed = Some(owner),
			Err(error) => return Err(retain(Err(error), environment.close().await).unwrap_err()),
		}
		Ok(environment)
	}
	async fn close(&self) -> Result<()> {
		if let Some(owner) = &self.managed {
			owner.close().await?;
		}
		let incoming = self.incoming.close().await;
		let (ice, runtime) = tokio::join!(self.ice.close(), self.runtime.close(PendingWork::Cancel));
		retain(
			incoming,
			retain(
				ice.map_err(|error| error.to_string()),
				runtime.map_err(|error| error.to_string()),
			),
		)
	}
}
fn scalar(value: js_sys::JsString, maximum: usize) -> Result<String> {
	crate::js_text::scalar(&value, maximum).map_err(|error| error.to_string())
}
fn safe_integer(value: f64) -> Result<u64> {
	if !value.is_finite() || !(0.0..=9_007_199_254_740_991.0).contains(&value) || value.fract() != 0.0 {
		Err("Rooms revision is outside the safe integer range".into())
	} else {
		Ok(value as u64)
	}
}
fn js_error(error: &str) -> JsValue {
	js_sys::Error::new(error).into()
}
fn rejected(error: String) -> js_sys::Promise {
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
		return Err("Too many Rooms command arguments".into());
	}
	let mut bytes = operation.len() + name.len();
	let mut values = Vec::with_capacity(arguments.length() as usize);
	for value in arguments.iter() {
		let value = value
			.dyn_into::<js_sys::JsString>()
			.map_err(|_| "Rooms command arguments must be strings")?;
		let value = scalar(value, 65_536)?;
		bytes += value.len();
		if bytes > driver::MAX_BYTES {
			return Err("Rooms command exceeds the retained input budget".into());
		}
		values.push(value);
	}
	Ok((operation, name, values, bytes))
}
