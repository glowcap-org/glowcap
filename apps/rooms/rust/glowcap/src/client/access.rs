//! Shared managed access over actual held controls. Revisions and receipt
//! sequences belong to the caller's retained request, including after timeout.
use super::*;
use glowcap::loam::{
	ControlDescription, ControlPowers, GrantDescription, InventoryPage, IssuePolicy, PolicyValue, UseDescription,
};
mod mutation;
mod observation;
pub use mutation::Mutation;
pub use observation::{Observation, ObservationRequest, ObservationState};

pub struct Control<D> {
	caller: Caller<D>,
	reference: Ref,
}
impl<D: Clone> Clone for Control<D> {
	fn clone(&self) -> Self {
		Self {
			caller: self.caller.clone(),
			reference: self.reference.clone(),
		}
	}
}
pub struct ControlState(Argument);
impl ControlState {
	pub fn view(&self) -> ControlDescription<'_> {
		ControlDescription::read(&self.0).expect("validated immutable control description")
	}
}
pub struct Inventory(Argument);
/// The held control's own target, including configured policy while use is
/// paused. This immutable description contains no use or control capability.
pub struct InspectedAccess(Argument);
/// Current use at the held control's immutable exact resource. Inactive use
/// reveals only its status; the control separately inspects configured terms.
pub struct UseState(pub(crate) Argument);
impl UseState {
	pub fn view(&self) -> UseDescription<'_> {
		UseDescription::read(&self.0).expect("validated immutable use inspection")
	}
}
impl InspectedAccess {
	pub fn view(&self) -> GrantDescription<'_> {
		GrantDescription::read(&self.0).expect("validated immutable access inspection")
	}
}
impl Inventory {
	pub fn view(&self) -> InventoryPage<'_> {
		InventoryPage::read(&self.0).expect("validated immutable inventory")
	}
}
/// Keep this complete request for exact issuance replay after interruption.
pub struct Issuance {
	arguments: Vec<Argument>,
}
impl Issuance {
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>().saturating_add(super::retained::vector(&self.arguments))
	}
	pub fn new(
		policy: IssuePolicy,
		sequence: u32,
		revision: u64,
		depth: u16,
		powers: ControlPowers,
		label: &str,
		paused: bool,
	) -> Self {
		Self {
			arguments: policy.issue_arguments(sequence, revision, depth, powers, label, paused),
		}
	}
}
/// Independent use and management custody, never recreated from inventory.
pub struct IssuedAccess {
	pub access: Ref,
	pub control: Ref,
}
impl<D: Deadline> Control<D> {
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self {
			caller: Caller::Remote(client),
			reference,
		}
	}
	pub fn local(host: glowcap::Host, platform: D, reference: Ref) -> Self {
		Self {
			caller: Caller::Local { host, platform },
			reference,
		}
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	/// The exact control's publication name, independent of any use endpoint.
	/// Resolve it at this capability's actual home. A local locator cannot name
	/// a foreign control; private bootstrap controls have no publication.
	pub async fn durable_name(&self) -> Result<String, Error> {
		let reply = self.call("durable-name", &[]).await?;
		reply
			.as_str()
			.filter(|name| !name.is_empty() && name.len() <= 64)
			.map(str::to_owned)
			.ok_or_else(|| glowcap::loam::refusal("invalid control publication name").into())
	}
	pub async fn derivation_sequence(&self) -> Result<u32, Error> {
		self.sequence("derivation-sequence").await
	}
	pub async fn mutation_sequence(&self) -> Result<u32, Error> {
		self.sequence("mutation-sequence").await
	}
	async fn sequence(&self, verb: &'static str) -> Result<u32, Error> {
		self.call(verb, &[])
			.await?
			.as_i64()
			.and_then(|value| u32::try_from(value).ok())
			.filter(|value| *value > 0)
			.ok_or_else(|| glowcap::loam::refusal("invalid access sequence").into())
	}
	pub async fn describe(&self) -> Result<ControlState, Error> {
		let reply = self.call("describe-control", &[]).await?;
		ControlDescription::read(&reply)?;
		Ok(ControlState(reply))
	}
	pub async fn inspect(&self) -> Result<InspectedAccess, Error> {
		let reply = self.call("inspect-access", &[]).await?;
		GrantDescription::read(&reply)?;
		Ok(InspectedAccess(reply))
	}
	/// Inspect effective access without obtaining or invoking the resource's use
	/// capability. This method requires Inspect and an exact-resource ceiling.
	pub async fn inspect_fixed_access(&self) -> Result<UseState, Error> {
		let reply = self.call("inspect-fixed-access", &[]).await?;
		UseDescription::read(&reply)?;
		Ok(UseState(reply))
	}
	pub async fn inventory(&self, cursor: Option<&[u8]>, limit: u8) -> Result<Inventory, Error> {
		if !(1..=32).contains(&limit) || cursor.is_some_and(|bytes| bytes.len() != 49) {
			return Err(glowcap::loam::refusal("invalid inventory page request").into());
		}
		let reply = self
			.call(
				"inventory",
				&[
					cursor.map_or(Argument::Void, |bytes| Argument::Bytes(bytes.to_vec())),
					i64::from(limit).into(),
				],
			)
			.await?;
		InventoryPage::read(&reply)?;
		Ok(Inventory(reply))
	}
	pub async fn issue(&self, request: &Issuance) -> Result<IssuedAccess, Error> {
		let reply = self.call("issue-access", &request.arguments).await?;
		let Some([Argument::Reference(access), Argument::Reference(control)]) = reply.as_list() else {
			return Err(glowcap::loam::refusal("managed issuance returned no access and control").into());
		};
		Ok(IssuedAccess {
			access: access.clone(),
			control: control.clone(),
		})
	}
	pub async fn set_policy(&self, sequence: u32, revision: u64, policy: PolicyValue) -> Result<(), Error> {
		self.call("mutate", &policy.set_policy_arguments(sequence, revision))
			.await?;
		Ok(())
	}
	pub async fn set_label(&self, sequence: u32, revision: u64, label: &str) -> Result<(), Error> {
		self.call("mutate", &ControlPowers::label_arguments(sequence, revision, label))
			.await?;
		Ok(())
	}
	pub async fn pause(&self, revision: u64) -> Result<(), Error> {
		self.lifecycle("pause", revision).await
	}
	pub async fn resume(&self, revision: u64) -> Result<(), Error> {
		self.lifecycle("resume", revision).await
	}
	pub async fn revoke(&self, revision: u64) -> Result<(), Error> {
		self.lifecycle("revoke", revision).await
	}
	async fn lifecycle(&self, verb: &'static str, revision: u64) -> Result<(), Error> {
		self.call(verb, &[Argument::Bytes(revision.to_be_bytes().to_vec())])
			.await?;
		Ok(())
	}
	pub async fn attenuate(&self, sequence: u32, powers: ControlPowers) -> Result<Ref, Error> {
		let reply = self.call("mutate", &powers.attenuation_arguments(sequence)).await?;
		Ref::try_from(&reply).map_err(|_| glowcap::loam::refusal("control attenuation returned no capability").into())
	}
	async fn call(&self, verb: &'static str, args: &[Argument]) -> Result<Argument, Error> {
		self.caller
			.call(&self.reference, verb, args, "the access control did not answer")
			.await
	}
}
