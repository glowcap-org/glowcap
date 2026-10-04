//! One consumer trace for both TCP/LMDB and Chromium/IndexedDB. Zig's grant
//! scenarios own semantics; this trace catches projection and persistence drift.
use super::{Argument, ControlPowers, Policy, Ref, Session};

fn request(policy: &Policy) -> Vec<Argument> {
	let wide = policy.value(&[10, 20], &[]).unwrap();
	wide.managed_derive_arguments(
		3,
		1,
		ControlPowers {
			policy_ceiling: Some(wide),
			pause: true,
			resume: true,
			revoke: true,
		},
	)
}
async fn derive(session: &Session, root: &Ref, policy: &Policy) -> (Ref, Ref) {
	let pair = session.send(root, "derive-managed", &request(policy)).await.unwrap();
	let pair = pair.as_list().unwrap();
	(Ref::try_from(&pair[0]).unwrap(), Ref::try_from(&pair[1]).unwrap())
}
async fn name(session: &Session, target: &Ref) -> String {
	session
		.send(target, "durable-name", &[])
		.await
		.unwrap()
		.as_str()
		.unwrap()
		.to_owned()
}
async fn policies(session: &Session, target: &Ref) {
	let description = session.send(target, "describe-access", &[]).await.unwrap();
	let Argument::Tagged { tag, value } = description else {
		panic!("missing access description")
	};
	assert_eq!(tag, "access:description");
	for (index, expected) in [(2, vec![10, 20]), (3, vec![10, 20]), (4, vec![10])] {
		let Argument::Tagged { tag, value } = &value[index] else {
			panic!("missing policy")
		};
		assert_eq!(tag, "access:policy");
		let keys: Vec<_> = value[0]
			.as_list()
			.unwrap()
			.iter()
			.map(|key| key.as_i64().unwrap())
			.collect();
		assert_eq!(
			keys, expected,
			"ancestor edits preserve a child's ceiling and configured policy"
		);
	}
}

pub async fn exercise(session: &Session, root: &Ref, root_control: &Ref, policy: &Policy) -> String {
	let wide = policy.value(&[10, 20], &[]).unwrap();
	let narrow = policy.value(&[10], &[]).unwrap();
	let (child, control) = derive(session, root, policy).await;
	let swiss = name(session, &child).await;
	let (replayed, _) = derive(session, root, policy).await;
	assert_eq!(
		name(session, &replayed).await,
		swiss,
		"managed derivation replays the exact child"
	);
	assert!(
		session
			.send(
				root,
				"derive-managed",
				&wide.managed_derive_arguments(3, 1, ControlPowers::default())
			)
			.await
			.is_err(),
		"same sequence with changed powers conflicts"
	);
	assert!(
		session.send(&child, "pause", &[]).await.is_err(),
		"use does not imply management"
	);
	let grandchild = session
		.send(&child, "derive", &wide.derive_arguments(1, 0))
		.await
		.unwrap();
	let grandchild = Ref::try_from(&grandchild).unwrap();
	assert!(
		session
			.send(&grandchild, "derive", &wide.derive_arguments(1, 0))
			.await
			.is_err(),
		"depth bounds descendant issuance"
	);

	assert!(
		session
			.send(
				&child,
				"derive-managed",
				&narrow.managed_derive_arguments(
					2,
					0,
					ControlPowers {
						policy_ceiling: Some(wide),
						..Default::default()
					}
				)
			)
			.await
			.is_err(),
		"child management cannot exceed the issued ceiling"
	);
	let narrow_child = session
		.send(
			&child,
			"derive-managed",
			&narrow.managed_derive_arguments(
				2,
				0,
				ControlPowers {
					pause: true,
					..Default::default()
				},
			),
		)
		.await
		.unwrap();
	let narrow_child = narrow_child.as_list().unwrap();
	let narrow_control = Ref::try_from(&narrow_child[1]).unwrap();
	assert!(
		session
			.send(&narrow_control, "mutate", &narrow.set_policy_arguments(1))
			.await
			.is_err()
	);
	assert!(session.send(&narrow_control, "revoke", &[]).await.is_err());

	let limited = ControlPowers {
		policy_ceiling: Some(narrow),
		pause: true,
		..Default::default()
	};
	let attenuation = limited.attenuation_arguments(1);
	let leaf = session.send(&control, "mutate", &attenuation).await.unwrap();
	let leaf = Ref::try_from(&leaf).unwrap();
	assert!(
		session.send(&control, "mutate", &attenuation).await.is_ok(),
		"attenuation receipt replays"
	);
	assert!(
		session
			.send(&leaf, "mutate", &wide.set_policy_arguments(1))
			.await
			.is_err(),
		"editing ceiling cannot expand"
	);
	assert!(session.send(&leaf, "resume", &[]).await.is_err());
	assert!(session.send(&leaf, "revoke", &[]).await.is_err());
	assert!(
		session
			.send(
				&leaf,
				"mutate",
				&ControlPowers {
					revoke: true,
					..Default::default()
				}
				.attenuation_arguments(1)
			)
			.await
			.is_err(),
		"attenuation cannot acquire a missing power"
	);
	let wrong_schema = Policy::new([6; 16], &[10, 20], &[]).unwrap().value(&[10], &[]).unwrap();
	assert!(
		session
			.send(&control, "mutate", &wrong_schema.set_policy_arguments(2))
			.await
			.is_err(),
		"schema mismatch cannot consume the mutation sequence"
	);
	let mut malformed = narrow.set_policy_arguments(2);
	malformed[2] = Argument::Bytes(vec![0; 15]);
	assert!(
		session.send(&control, "mutate", &malformed).await.is_err(),
		"malformed policy refuses without changing authority"
	);
	session
		.send(&control, "mutate", &narrow.set_policy_arguments(2))
		.await
		.unwrap();
	policies(session, &grandchild).await;
	session.send(&leaf, "pause", &[]).await.unwrap();
	session
		.send(&control, "mutate", &wide.set_policy_arguments(3))
		.await
		.unwrap();
	assert!(
		session.send(&child, "get", &[]).await.is_err(),
		"editing a paused grant does not resume it"
	);
	session.send(&control, "resume", &[]).await.unwrap();
	assert!(session.send(&grandchild, "get", &[]).await.is_ok());
	let dependent = session
		.send(
			&leaf,
			"mutate",
			&ControlPowers {
				pause: true,
				..Default::default()
			}
			.attenuation_arguments(1),
		)
		.await
		.unwrap();
	let dependent = Ref::try_from(&dependent).unwrap();
	assert!(
		session
			.send(&dependent, "mutate", &narrow.set_policy_arguments(1))
			.await
			.is_err(),
		"lifecycle-only control cannot edit policy"
	);
	session.send(&leaf, "revoke-control", &[]).await.unwrap();
	assert!(session.send(&leaf, "pause", &[]).await.is_err());
	assert!(
		session.send(&dependent, "pause", &[]).await.is_err(),
		"control retirement fences its dependent controls"
	);
	assert!(
		session.send(&child, "get", &[]).await.is_ok(),
		"control retirement preserves use and independent control"
	);
	session.send(root_control, "pause", &[]).await.unwrap();
	assert!(session.send(&grandchild, "get", &[]).await.is_err());
	session.send(root_control, "resume", &[]).await.unwrap();
	session
		.send(&control, "mutate", &narrow.set_policy_arguments(4))
		.await
		.unwrap();
	policies(session, &grandchild).await;
	swiss
}

pub async fn reopen(session: &Session, root: &Ref, policy: &Policy, swiss: &str) {
	let (child, control) = derive(session, root, policy).await;
	assert_eq!(name(session, &child).await, swiss, "managed receipt survives restart");
	let narrow = policy.value(&[10], &[]).unwrap();
	assert_eq!(
		session
			.send(&control, "mutate", &narrow.set_policy_arguments(4))
			.await
			.unwrap()
			.as_bool(),
		Some(true),
		"policy receipt survives restart"
	);
	let grandchild = session
		.send(
			&child,
			"derive",
			&policy.value(&[10, 20], &[]).unwrap().derive_arguments(1, 0),
		)
		.await
		.unwrap();
	let grandchild = Ref::try_from(&grandchild).unwrap();
	policies(session, &grandchild).await;
	let denied = vec![
		Argument::Integer(1),
		Argument::String("set".into()),
		Argument::Bytes(b"edited".to_vec()),
	];
	assert!(
		session.send(&child, "mutate", &denied).await.is_err(),
		"configured policy persists"
	);
	session
		.send(
			&control,
			"mutate",
			&policy.value(&[10, 20], &[]).unwrap().set_policy_arguments(5),
		)
		.await
		.unwrap();
	assert!(
		session.send(&child, "mutate", &denied).await.is_ok(),
		"held editing ceiling persists"
	);
	session.send(&control, "revoke", &[]).await.unwrap();
	assert_eq!(
		session.send(&control, "revoke", &[]).await.unwrap().as_bool(),
		Some(false),
		"terminal grant revocation remains idempotent"
	);
	assert!(session.send(&child, "get", &[]).await.is_err());
	assert!(
		session.send(&grandchild, "get", &[]).await.is_err(),
		"grant revocation fences retained descendants"
	);
	assert!(
		session.send(root, "derive-managed", &request(policy)).await.is_err(),
		"receipt replay cannot resurrect revoked access"
	);
	assert!(
		session.send(root, "get", &[]).await.is_ok(),
		"a descendant cannot revoke its source"
	);
}
