//! A real content target records upstream dispatch and controlled replies.
use super::*;

pub(super) const TARGET: Schema = Schema {
	id: 0x534f504552303031,
	version: 1,
	max_payload: 64,
	max_edges: 1,
};
struct Target {
	calls: Rc<Cell<usize>>,
	malformed: Rc<Cell<bool>>,
	case: Case,
	revoked: Rc<std::cell::RefCell<Option<String>>>,
}
impl Content for Target {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		assert_eq!(
			input.payload, b"original",
			"workspace replacement cannot redirect retained work"
		);
		assert_eq!(input.verb, self.case.verb);
		let expected = if self.case.name == "revokeManagedRoomAuthority" {
			vec![
				self.revoked
					.borrow()
					.as_ref()
					.expect("saved publication identity")
					.clone()
					.into(),
			]
		} else {
			self.case
				.forwarded
				.iter()
				.cloned()
				.map(rooms_glowcap::effect_argument)
				.collect::<Vec<_>>()
		};
		assert_eq!(input.args, expected);
		self.calls.set(self.calls.get() + 1);
		Ok(if self.malformed.get() {
			true.into()
		} else {
			self.case.reply()
		})
	}
}
pub(super) fn target_registration(calls: Rc<Cell<usize>>, malformed: Rc<Cell<bool>>, case: &Case) -> Registration {
	target_registration_with_token(calls, malformed, case, Rc::new(std::cell::RefCell::new(None)))
}
pub(super) fn target_registration_with_token(
	calls: Rc<Cell<usize>>,
	malformed: Rc<Cell<bool>>,
	case: &Case,
	revoked: Rc<std::cell::RefCell<Option<String>>>,
) -> Registration {
	Registration {
		schema: TARGET.id,
		version: 1,
		graph: None,
		methods: vec![Method {
			verb: case.verb.into(),
			retry: Retry::ReadOnly,
		}],
		content: Box::new(Target {
			calls,
			malformed,
			case: case.clone(),
			revoked,
		}),
	}
}
