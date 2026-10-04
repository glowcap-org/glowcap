//! Direct wire requests must obey the persisted descriptor even after reopen.
use super::{Argument, ControlPowers, Policy, Ref, Session};

fn post_only(mask: &mut Argument) {
	*mask = Argument::List(vec![Argument::Bytes(2u64.to_be_bytes().to_vec())]);
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
	let mut derive = wide.derive_arguments(derivation, 0);
	post_only(&mut derive[2]);
	assert!(
		session
			.send(root, "derive", &derive)
			.await
			.unwrap_err()
			.to_string()
			.contains("MissingPrerequisite")
	);
	let mut edit = wide.set_policy_arguments(mutation);
	post_only(&mut edit[3]);
	assert!(
		session
			.send(control, "mutate", &edit)
			.await
			.unwrap_err()
			.to_string()
			.contains("MissingPrerequisite")
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
	post_only(&mut ceiling[1]);
	assert!(
		session
			.send(control, "mutate", &attenuation)
			.await
			.unwrap_err()
			.to_string()
			.contains("MissingPrerequisite")
	);
	// Refusal leaves the sequence usable and the held source intact.
	session
		.send(root, "derive", &wide.derive_arguments(derivation, 0))
		.await
		.unwrap();
	session
		.send(control, "mutate", &wide.set_policy_arguments(mutation))
		.await
		.unwrap();
}
