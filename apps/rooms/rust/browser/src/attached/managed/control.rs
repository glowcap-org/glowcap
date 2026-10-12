//! Explicit held management and exact retained issuance/edit requests.
use super::*;
use glowcap::loam::{ControlPowers, IssuePolicy, PolicyValue};
use rooms_application::content::{permissions::Permission, session as content};
use rooms_glowcap::client::access::{Issuance, Mutation};
use serde::Deserialize;

/// Management powers are independent choices. Missing powers remain absent.
/// Each ceiling is validated as a policy and checked by the held control.
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Powers {
	inspect: bool,
	pause: bool,
	resume: bool,
	revoke: bool,
	delegate_control: bool,
	issue_ceiling: Option<Vec<Permission>>,
	edit_ceiling: Option<Vec<Permission>>,
}
impl Powers {
	fn read(raw: js_sys::JsString) -> Result<ControlPowers> {
		let raw = scalar(raw, 8192)?;
		let powers: Self = serde_json::from_str(&raw).map_err(|_| "Invalid management powers")?;
		Ok(ControlPowers {
			inspect: powers.inspect,
			pause: powers.pause,
			resume: powers.resume,
			revoke: powers.revoke,
			delegate_control: powers.delegate_control,
			issue_ceiling: powers.issue_ceiling.as_deref().map(policy_values).transpose()?,
			policy_ceiling: powers.edit_ceiling.as_deref().map(policy_values).transpose()?,
		})
	}
}

fn policy(raw: js_sys::JsString) -> Result<PolicyValue> {
	let raw = scalar(raw, 4096)?;
	let values: Vec<Permission> = serde_json::from_str(&raw).map_err(|_| "Invalid permission selection")?;
	policy_values(&values)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IssuePermissions {
	ceiling: Vec<Permission>,
	configured: Vec<Permission>,
}
fn issue_policy(raw: js_sys::JsString) -> Result<IssuePolicy> {
	let raw = scalar(raw, 8192)?;
	let values: IssuePermissions = serde_json::from_str(&raw).map_err(|_| "Invalid issuance permissions")?;
	Ok(policy_values(&values.configured)?.with_ceiling(policy_values(&values.ceiling)?))
}
fn policy_values(values: &[Permission]) -> Result<PolicyValue> {
	rooms_application::content::permissions::validate(values, content::SUPPORTED).map_err(|e| e.to_string())?;
	rooms_glowcap::policy::descriptor()
		.and_then(|policy| {
			policy.value_for_kind(
				content::KIND,
				&values.iter().map(|permission| permission.key()).collect::<Vec<_>>(),
				&[],
			)
		})
		.map_err(|e| e.to_string())
}
#[wasm_bindgen]
pub struct RoomsManagedControl {
	driver: Driver,
	control: Held<Control<Platform>>,
	pub(super) home: PublicationHome,
}
impl RoomsManagedControl {
	pub(super) fn new(driver: Driver, control: Control<Platform>, home: PublicationHome) -> Result<Self> {
		let control = driver.hold(control, size_of::<Control<Platform>>())?;
		Ok(Self { driver, control, home })
	}
	pub(super) fn reference(&self) -> &Ref {
		self.control.reference()
	}
}
#[wasm_bindgen]
impl RoomsManagedControl {
	/// Share this exact control, including an issued or attenuated local branch.
	/// Attached and restored handles retain authority without assuming a home.
	pub fn publish(&self) -> js_sys::Promise {
		self.home.publish(&self.driver, self.reference())
	}
	pub fn describe(&self) -> js_sys::Promise {
		let control = self.control.clone();
		self.driver.submit(0, move |_| async move {
			let description = control.describe().await.map_err(|e| e.to_string())?;
			json(&projection::control(description.view()).to_string())
		})
	}
	pub fn inspect(&self) -> js_sys::Promise {
		let control = self.control.clone();
		self.driver.submit(0, move |_| async move {
			let target = control.inspect().await.map_err(|e| e.to_string())?;
			json(&projection::grant(target.view()).to_string())
		})
	}
	/// Effective permissions come from the shared evaluator, independently of
	/// workspace observation powers and without restoring a use capability.
	#[wasm_bindgen(js_name = inspectEffective)]
	pub fn inspect_effective(&self) -> js_sys::Promise {
		let control = self.control.clone();
		self.driver.submit(0, move |_| async move {
			let target = control.inspect_fixed_access().await.map_err(|e| e.to_string())?;
			json(&projection::use_access(target.view()).to_string())
		})
	}
	/// Cursor bytes are descriptive paging data. They cannot address a control
	/// or restore authority. Every page uses this independently held control.
	pub fn inventory(&self, cursor: Option<js_sys::Uint8Array>) -> js_sys::Promise {
		let cursor = match cursor
			.map(|cursor| {
				if cursor.length() != 49 {
					return Err("Invalid inventory cursor".into());
				}
				let mut bytes = [0; 49];
				cursor.copy_to(&mut bytes);
				Ok(bytes)
			})
			.transpose()
		{
			Ok(cursor) => cursor,
			Err(error) => return rejected(error),
		};
		let control = self.control.clone();
		self.driver
			.submit(cursor.as_ref().map_or(0, |_| 49), move |_| async move {
				let page = control
					.inventory(cursor.as_ref().map(|bytes| bytes.as_slice()), 32)
					.await
					.map_err(|e| e.to_string())?;
				let view = page.view();
				let output = json(
					&serde_json::json!({"rows": view.rows().map(projection::grant).collect::<Vec<_>>()}).to_string(),
				)?;
				let cursor = view
					.cursor
					.map_or(JsValue::NULL, |cursor| js_sys::Uint8Array::from(cursor).into());
				js_sys::Reflect::set(&output, &"cursor".into(), &cursor)
					.map_err(|_| "Inventory cursor projection failed")?;
				Ok(output)
			})
	}
	#[wasm_bindgen(js_name = prepareIssue)]
	pub fn prepare_issue(
		&self,
		expected: js_sys::JsString,
		permissions: js_sys::JsString,
		label: js_sys::JsString,
		paused: bool,
		depth: u16,
		powers: js_sys::JsString,
	) -> js_sys::Promise {
		let input = (|| {
			Ok((
				scalar(expected, 20).and_then(|text| revision(&text))?,
				issue_policy(permissions)?,
				scalar(label, 120)?,
				Powers::read(powers)?,
			))
		})();
		let (expected, policy, label, powers) = match input {
			Ok(input) => input,
			Err(error) => return rejected(error),
		};
		let control = self.control.clone();
		let driver = self.driver.clone();
		let home = self.home.clone();
		self.driver.submit(label.len(), move |_| async move {
			let sequence = control.derivation_sequence().await.map_err(|e| e.to_string())?;
			let request = Issuance::new(policy, sequence, expected, depth, powers, &label, paused);
			let bytes = request.retained_bytes();
			let request = driver.hold(request, bytes)?;
			Ok(RoomsManagedIssuance {
				driver,
				control,
				request,
				home,
			}
			.into())
		})
	}
	#[wasm_bindgen(js_name = preparePolicy)]
	pub fn prepare_policy(&self, expected: js_sys::JsString, permissions: js_sys::JsString) -> js_sys::Promise {
		let expected = match scalar(expected, 20).and_then(|text| revision(&text)) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let policy = match policy(permissions) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		self.prepare_edit(expected, Edit::Policy(policy))
	}
	#[wasm_bindgen(js_name = prepareLabel)]
	pub fn prepare_label(&self, expected: js_sys::JsString, label: js_sys::JsString) -> js_sys::Promise {
		let input = (|| Ok((revision(&scalar(expected, 20)?)?, scalar(label, 120)?)))();
		match input {
			Ok((expected, label)) => self.prepare_edit(expected, Edit::Label(label)),
			Err(error) => rejected(error),
		}
	}
	#[wasm_bindgen(js_name = prepareAttenuation)]
	pub fn prepare_attenuation(&self, powers: js_sys::JsString) -> js_sys::Promise {
		let powers = match Powers::read(powers) {
			Ok(powers) => powers,
			Err(error) => return rejected(error),
		};
		let control = self.control.clone();
		let driver = self.driver.clone();
		let home = self.home.clone();
		self.driver.submit(0, move |_| async move {
			let sequence = control.mutation_sequence().await.map_err(|e| e.to_string())?;
			let request = driver.hold(
				Attenuation {
					control,
					sequence,
					powers,
					home,
				},
				size_of::<Attenuation>(),
			)?;
			Ok(RoomsManagedAttenuation { driver, request }.into())
		})
	}
	#[wasm_bindgen(js_name = preparePause)]
	pub fn prepare_pause(&self, expected: js_sys::JsString) -> js_sys::Promise {
		self.lifecycle("pause", expected)
	}
	#[wasm_bindgen(js_name = prepareResume)]
	pub fn prepare_resume(&self, expected: js_sys::JsString) -> js_sys::Promise {
		self.lifecycle("resume", expected)
	}
	#[wasm_bindgen(js_name = prepareRevoke)]
	pub fn prepare_revoke(&self, expected: js_sys::JsString) -> js_sys::Promise {
		self.lifecycle("revoke", expected)
	}
}
impl RoomsManagedControl {
	fn prepare_edit(&self, expected: u64, edit: Edit) -> js_sys::Promise {
		let bytes = match &edit {
			Edit::Label(label) => label.capacity(),
			Edit::Policy(_) | Edit::Lifecycle(_) => 0,
		};
		let control = self.control.clone();
		let driver = self.driver.clone();
		self.driver.submit(bytes, move |_| async move {
			let request = match edit {
				Edit::Policy(policy) => control.prepare_policy(expected, policy).await,
				Edit::Label(label) => control.prepare_label(expected, &label).await,
				Edit::Lifecycle("pause") => control.prepare_pause(expected).await,
				Edit::Lifecycle("resume") => control.prepare_resume(expected).await,
				Edit::Lifecycle("revoke") => control.prepare_revoke(expected).await,
				Edit::Lifecycle(_) => unreachable!(),
			}
			.map_err(|e| e.to_string())?;
			let bytes = request.retained_bytes();
			let request = driver.hold(request, bytes)?;
			Ok(RoomsManagedEdit { driver, request }.into())
		})
	}
	fn lifecycle(&self, verb: &'static str, expected: js_sys::JsString) -> js_sys::Promise {
		let expected = match scalar(expected, 20).and_then(|text| revision(&text)) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		self.prepare_edit(expected, Edit::Lifecycle(verb))
	}
}
#[wasm_bindgen]
pub struct RoomsManagedIssuance {
	driver: Driver,
	control: Held<Control<Platform>>,
	request: Held<Issuance>,
	home: PublicationHome,
}
#[wasm_bindgen]
impl RoomsManagedIssuance {
	pub fn submit(&self) -> js_sys::Promise {
		self.submission(false)
	}
	#[wasm_bindgen(js_name = submitOutcome)]
	pub fn submit_outcome(&self) -> js_sys::Promise {
		self.submission(true)
	}
}
impl RoomsManagedIssuance {
	fn submission(&self, outcome: bool) -> js_sys::Promise {
		let control = self.control.clone();
		let request = self.request.clone();
		let driver = self.driver.clone();
		let home = self.home.clone();
		self.driver.submit(0, move |environment| async move {
			let issued = match control.issue(&request).await {
				Ok(issued) => issued,
				Err(error) => {
					return if outcome {
						super::outcome::failed(error)
					} else {
						Err(error.to_string())
					};
				}
			};
			let host = environment.runtime.host().clone();
			let workspace = Workspace::local(host.clone(), environment.platform.clone(), issued.access);
			let workspace = driver.hold(workspace, size_of::<Workspace<Platform>>())?;
			let workspace = RoomsManagedWorkspace {
				driver: driver.clone(),
				workspace,
				home: home.clone(),
			};
			let control = RoomsManagedControl::new(
				driver,
				Control::local(host, environment.platform.clone(), issued.control),
				home,
			)?;
			if outcome {
				let output = json(r#"{"status":"committed"}"#)?;
				super::super::view::set(&output, "access", workspace.into())?;
				super::super::view::set(&output, "control", control.into())?;
				Ok(output)
			} else {
				Ok(js_sys::Array::of2(&workspace.into(), &control.into()).into())
			}
		})
	}
}
#[wasm_bindgen]
pub struct RoomsManagedEdit {
	pub(super) driver: Driver,
	pub(super) request: Held<Mutation<Platform>>,
}
enum Edit {
	Policy(PolicyValue),
	Label(String),
	Lifecycle(&'static str),
}
#[wasm_bindgen]
impl RoomsManagedEdit {
	pub fn submit(&self) -> js_sys::Promise {
		let request = self.request.clone();
		self.driver.submit(0, move |_| async move {
			request.submit().await.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
struct Attenuation {
	control: Held<Control<Platform>>,
	sequence: u32,
	powers: ControlPowers,
	home: PublicationHome,
}
#[wasm_bindgen]
pub struct RoomsManagedAttenuation {
	driver: Driver,
	request: Held<Attenuation>,
}
#[wasm_bindgen]
impl RoomsManagedAttenuation {
	pub fn submit(&self) -> js_sys::Promise {
		let request = self.request.clone();
		let driver = self.driver.clone();
		self.driver.submit(0, move |environment| async move {
			let reference = request
				.control
				.attenuate(request.sequence, request.powers)
				.await
				.map_err(|e| e.to_string())?;
			RoomsManagedControl::new(
				driver,
				Control::local(
					environment.runtime.host().clone(),
					environment.platform.clone(),
					reference,
				),
				request.home.clone(),
			)
			.map(Into::into)
		})
	}
}
