//! Direct wire requests must obey the persisted descriptor even after reopen.
use super::{Argument, ControlPowers, Policy, Ref, Scope, Session};

pub fn descriptor() -> Policy {
	Policy::with_dependencies([5; 16], &[10, 20, 30], &[], &[(20, 10)])
		.unwrap()
		.with_kinds(&[super::KindRule {
			kind: 1,
			permissions: &[10, 20],
			subtree_permissions: &[10, 20],
		}])
		.unwrap()
}
fn permissions(mask: &mut Argument, bits: u64) {
	*mask = Argument::List(vec![Argument::Bytes(bits.to_be_bytes().to_vec())]);
}

pub async fn exercise(session: &Session, root: &Ref, control: &Ref, policy: &Policy) {
	let wide = policy.value(&[10, 20], &[]).unwrap();
	let derivation = u32::try_from(
		session
			.send(root, "derivation-sequence", &[])
			.await
			.unwrap()
			.as_i64()
			.unwrap(),
	)
	.unwrap();
	let mutation = u32::try_from(
		session
			.send(control, "mutation-sequence", &[])
			.await
			.unwrap()
			.as_i64()
			.unwrap(),
	)
	.unwrap();
	for (bits, reason) in [(2, "MissingPrerequisite"), (4, "InapplicablePermission")] {
		let mut derive = wide.derive_arguments(derivation, Scope::Object, 0);
		permissions(&mut derive[3], bits);
		assert!(
			session
				.send(root, "derive", &derive)
				.await
				.unwrap_err()
				.to_string()
				.contains(reason)
		);
		let mut edit = wide.set_policy_arguments(mutation, super::management::revision(session, control).await);
		permissions(&mut edit[4], bits);
		assert!(
			session
				.send(control, "mutate", &edit)
				.await
				.unwrap_err()
				.to_string()
				.contains(reason)
		);
		let mut attenuation = ControlPowers {
			policy_ceiling: Some(wide),
			..Default::default()
		}
		.attenuation_arguments(mutation);
		let Argument::List(powers) = &mut attenuation[2] else {
			panic!("control powers")
		};
		let Argument::List(ceiling) = &mut powers[0] else {
			panic!("policy ceiling")
		};
		permissions(&mut ceiling[1], bits);
		assert!(
			session
				.send(control, "mutate", &attenuation)
				.await
				.unwrap_err()
				.to_string()
				.contains(reason)
		);
	}
	// Refusal leaves the sequence usable and the held source intact.
	session
		.send(root, "derive", &wide.derive_arguments(derivation, Scope::Object, 0))
		.await
		.unwrap();
	session
		.send(
			control,
			"mutate",
			&wide.set_policy_arguments(mutation, super::management::revision(session, control).await),
		)
		.await
		.unwrap();
}
