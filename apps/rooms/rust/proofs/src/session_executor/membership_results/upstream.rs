//! Hosted subscription fixture and its observable invocation facts.
use super::*;
pub(in crate::session_executor) const MEMBER: Schema = Schema {
	id: 0x534d454d42303031,
	version: 1,
	max_payload: 64,
	max_edges: 5,
};
struct Upstream {
	joins: Rc<Cell<usize>>,
	acts: Rc<Cell<usize>>,
	notices: Rc<Cell<usize>>,
	retirements: Rc<Cell<usize>>,
	options: u8,
	nickname: std::cell::RefCell<String>,
	standing: std::cell::RefCell<String>,
	standing_calls: Cell<usize>,
}
impl Content for Upstream {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if matches!(input.verb, "subscribe" | "register") {
			(0..3)
				.map(loam::ReferenceRequest::Restore)
				.chain(core::iter::once(loam::ReferenceRequest::SaveLive(
					Ref::try_from(&input.args[if input.verb == "register" { 2 } else { 1 }]).unwrap(),
				)))
				.collect()
		} else if input.verb == "inbox" {
			vec![loam::ReferenceRequest::Restore(3)]
		} else {
			Vec::new()
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			"away" => {
				let [reason] = input.args else { panic!("one standing") };
				*self.standing.borrow_mut() = reason.as_str().unwrap().into();
				self.standing_calls.set(self.standing_calls.get() + 1);
				Ok(Argument::Void)
			}
			"last-standing" => Ok(self.standing.borrow().clone().into()),
			"standing-count" => Ok((self.standing_calls.get() as i64).into()),
			"leave" => {
				assert_eq!(
					input.payload,
					if self.options == 7 { b"name" } else { b"seat" },
					"retirement must select the exact returned lifetime"
				);
				assert!(input.args.is_empty(), "retirement carries no substitute authority");
				self.retirements.set(self.retirements.get() + 1);
				Ok(Argument::Void)
			}
			"last-nickname" => Ok(self.nickname.borrow().clone().into()),
			"configure" => {
				for field in input.args {
					call.append_reference(&Ref::try_from(field).unwrap())?;
				}
				Ok(Argument::Void)
			}
			"subscribe" => {
				assert_eq!(
					input.payload, b"entrance",
					"replacement entrance cannot redirect admitted work"
				);
				let [nick, inbox] = input.args else {
					panic!("exact subscription inputs")
				};
				assert!(nick.as_str().is_some_and(rooms_application::room::inbox::valid_nick));
				*self.nickname.borrow_mut() = nick.as_str().unwrap().into();
				let inbox = Ref::try_from(inbox).unwrap();
				if input.field_count == 3 {
					call.append_reference(&inbox)?;
				} else {
					call.replace_reference(3, &inbox)?;
				}
				self.joins.set(self.joins.get() + 1);
				if self.options == 6 {
					return Err(loam::refusal("upstream admission has an unknown outcome"));
				}
				Ok(Argument::List(vec![
					call.disclose(0, false)?,
					"participant".into(),
					if self.options & 1 != 0 {
						call.disclose(1, false)?
					} else {
						Argument::Void
					},
					if self.options & 2 != 0 {
						call.disclose(2, false)?
					} else {
						Argument::Void
					},
				]))
			}
			"register" => {
				assert_eq!(input.payload, b"entrance");
				let [nick, locator, Argument::Reference(inbox), allocation] = input.args else {
					panic!("exact registration inputs")
				};
				assert_eq!(nick.as_str(), Some("member"));
				assert_eq!(locator.as_str(), Some("ocapn://member.id"));
				assert_eq!(allocation.as_str(), Some("exact"));
				call.append_reference(inbox)?;
				self.joins.set(self.joins.get() + 1);
				Ok(Argument::List(vec![
					"member".into(),
					"00000000-0000-4000-8000-000000000001".into(),
					call.disclose(0, false)?,
				]))
			}
			"inbox" => call.disclose(3, false),
			"notify" => {
				assert_eq!(
					input.payload, b"inbox",
					"replacement inbox cannot receive original notices"
				);
				self.notices.set(self.notices.get() + 1);
				Ok(Argument::Void)
			}
			"typing" | "setTopic" | "post" => {
				self.acts.set(self.acts.get() + 1);
				Ok(Argument::Void)
			}
			_ => Err(loam::refusal("unsupported membership fixture method")),
		}
	}
}
pub(in crate::session_executor) fn registration(
	joins: Rc<Cell<usize>>,
	acts: Rc<Cell<usize>>,
	notices: Rc<Cell<usize>>,
	options: u8,
) -> Registration {
	registration_with_retirement(joins, acts, notices, options, Rc::new(Cell::new(0)))
}
pub(in crate::session_executor) fn registration_with_retirement(
	joins: Rc<Cell<usize>>,
	acts: Rc<Cell<usize>>,
	notices: Rc<Cell<usize>>,
	options: u8,
	retirements: Rc<Cell<usize>>,
) -> Registration {
	Registration {
		schema: MEMBER.id,
		version: 1,
		graph: None,
		methods: [
			"inbox",
			"typing",
			"setTopic",
			"notify",
			"post",
			"last-nickname",
			"away",
			"last-standing",
			"standing-count",
		]
		.into_iter()
		.map(|verb| Method {
			verb: verb.into(),
			retry: Retry::ReadOnly,
		})
		.chain(core::iter::once(Method {
			verb: "leave".into(),
			retry: Retry::Idempotent,
		}))
		.chain(core::iter::once(Method {
			verb: "configure".into(),
			retry: Retry::Idempotent,
		}))
		.chain(core::iter::once(Method {
			verb: "subscribe".into(),
			retry: Retry::Idempotent,
		}))
		.chain(core::iter::once(Method {
			verb: "register".into(),
			retry: Retry::Idempotent,
		}))
		.collect(),
		content: Box::new(Upstream {
			joins,
			acts,
			notices,
			retirements,
			options,
			nickname: Default::default(),
			standing: Default::default(),
			standing_calls: Cell::new(0),
		}),
	}
}
