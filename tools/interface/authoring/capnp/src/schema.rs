//! Projection of compiler-owned schema nodes, not of Cap'n Proto source text.
use crate::{Result, syrup::Value as V};
use capnp::schema_capnp::{annotation, brand, code_generator_request, field, node, type_, value};
use std::{cell::Cell, collections::BTreeMap};

type Annotations = BTreeMap<String, V>;
struct Schema<'a> {
	nodes: BTreeMap<u64, node::Reader<'a>>,
	annotations: BTreeMap<u64, String>,
	names: BTreeMap<u64, String>,
	output_payload_left: Cell<usize>,
}
fn text(value: capnp::text::Reader<'_>) -> Result<String> {
	Ok(value.to_str()?.into())
}

pub fn translate(request: code_generator_request::Reader<'_>) -> Result<V> {
	let version = request.get_capnp_version()?;
	if (version.get_major(), version.get_minor(), version.get_micro()) != (1, 1, 0) {
		return Err("unsupported compiler request version; comparison requires Cap'n Proto 1.1.0".into());
	}
	let files = request.get_requested_files()?;
	if files.len() != 1 {
		return Err("exactly one requested schema file is required".into());
	}
	let nodes = request.get_nodes()?;
	if nodes.len() > 4096 {
		return Err("compiler request exceeds 4096 nodes".into());
	}
	let mut schema = Schema {
		nodes: BTreeMap::new(),
		annotations: BTreeMap::new(),
		names: BTreeMap::new(),
		output_payload_left: Cell::new(crate::MAX_DESCRIPTION_BYTES),
	};
	for entry in nodes {
		if schema.nodes.insert(entry.get_id(), entry).is_some() {
			return Err("duplicate schema node".into());
		}
	}
	let file = schema.node(files.get(0).get_id())?;
	if !matches!(file.which()?, node::File(())) {
		return Err("requested node is not a file".into());
	}
	for child in file.get_nested_nodes()? {
		let declaration = schema.node(child.get_id())?;
		if matches!(declaration.which()?, node::Annotation(_)) {
			schema.annotations.insert(child.get_id(), text(child.get_name()?)?);
		}
	}
	let annotations = schema.annotations(file.get_annotations()?, &["module"])?;
	let module = match annotations.get("module") {
		Some(V::Text(name)) => name,
		_ => return Err("file needs a module annotation".into()),
	};
	for child in file.get_nested_nodes()? {
		let declaration = schema.node(child.get_id())?;
		if !matches!(declaration.which()?, node::Annotation(_)) {
			let short = child.get_name()?;
			// Every qualified definition name is a mandatory output key.
			schema.charge_output_payload(module.len() + 1 + short.len())?;
			schema
				.names
				.insert(child.get_id(), format!("{module}.{}", short.to_str()?));
		}
	}
	let mut definitions = Vec::new();
	let mut receipt_convention = false;
	let mut work = 0usize;
	for (&id, name) in &schema.names {
		let declaration = schema.node(id)?;
		if !declaration.get_parameters()?.is_empty() || declaration.get_is_generic() {
			return Err("generic declarations are unsupported".into());
		}
		if !declaration.get_nested_nodes()?.is_empty() {
			return Err("nested declarations are unsupported".into());
		}
		let definition = match declaration.which()? {
			node::Interface(interface) => {
				schema.annotations(declaration.get_annotations()?, &[])?;
				if !interface.get_superclasses()?.is_empty() {
					return Err("inheritance is unsupported".into());
				}
				let mut methods = Vec::new();
				for method in interface.get_methods()? {
					work += 1;
					if work > 65536 {
						return Err("description work budget exceeded".into());
					}
					if !method.get_implicit_parameters()?.is_empty() {
						return Err("generic methods are unsupported".into());
					}
					if !method.get_param_brand()?.get_scopes()?.is_empty()
						|| !method.get_result_brand()?.get_scopes()?.is_empty()
					{
						return Err("generic method brands are unsupported".into());
					}
					let ann = schema.annotations(method.get_annotations()?, &["direct", "wireName", "delivery"])?;
					let selector = if ann.contains_key("direct") {
						if ann.contains_key("wireName") {
							return Err("direct and wireName conflict".into());
						}
						V::Boolean(false)
					} else {
						match ann.get("wireName") {
							Some(V::Text(name)) => {
								schema.charge_output_payload(name.len())?;
								V::Text(name.clone())
							}
							_ => schema.output_text(method.get_name()?)?,
						}
					};
					let mut parameters = Vec::new();
					let inputs = schema.fields(method.get_param_struct_type())?;
					if inputs.len() > 256 {
						return Err("method exceeds 256 parameters".into());
					}
					work += inputs.len();
					if work > 65536 {
						return Err("description work budget exceeded".into());
					}
					for parameter in inputs {
						let ann =
							schema.annotations(parameter.get_annotations()?, &["optional", "nullValue", "pending"])?;
						parameters.push(V::record(
							"parameter",
							vec![
								schema.output_text(parameter.get_name()?)?,
								schema.field_type(parameter, &ann)?,
								V::Boolean(ann.contains_key("optional")),
							],
						));
					}
					let result = schema.fields(method.get_result_struct_type())?;
					if result.len() != 1 {
						return Err("methods need exactly one result field".into());
					}
					let ann_result = schema.annotations(result[0].get_annotations()?, &["nullValue"])?;
					let result = schema.field_type(result[0], &ann_result)?;
					let delivery = match ann.get("delivery") {
						None => "call",
						Some(V::Text(value)) if ["call", "tell", "loam.receipt"].contains(&value.as_str()) => value,
						_ => return Err("unsupported delivery convention".into()),
					};
					receipt_convention |= delivery == "loam.receipt";
					methods.push((
						selector,
						V::record("method", vec![V::List(parameters), result, V::symbol(delivery)]),
					));
				}
				V::record("interface", vec![V::Dictionary(methods)])
			}
			node::Struct(_) => {
				let ann = schema.annotations(declaration.get_annotations()?, &["alias"])?;
				if !ann.contains_key("alias") {
					return Err("copied structs are outside this comparison".into());
				}
				let fields = schema.fields(id)?;
				if fields.len() != 1 {
					return Err("aliases need exactly one field".into());
				}
				let ann = schema.annotations(fields[0].get_annotations()?, &["min", "max", "minBytes", "maxBytes"])?;
				V::record("type", vec![schema.field_type(fields[0], &ann)?])
			}
			_ => return Err("unsupported named declaration".into()),
		};
		definitions.push((V::Text(name.clone()), definition));
	}
	let mut profiles = vec![(V::Text("glowcap.values".into()), V::Integer(1))];
	if receipt_convention {
		profiles.push((V::Text("loam.receipt".into()), V::Integer(1)));
	}
	Ok(V::record(
		"glowcap:interface",
		vec![V::Integer(1), V::Dictionary(profiles), V::Dictionary(definitions)],
	))
}
impl<'a> Schema<'a> {
	// Variable payload bytes are a lower bound on canonical output size. Charge
	// before expanding names, including repeated references to one schema node.
	fn charge_output_payload(&self, bytes: usize) -> Result<()> {
		let left = self
			.output_payload_left
			.get()
			.checked_sub(bytes)
			.ok_or("expanded output exceeds 1 MiB")?;
		self.output_payload_left.set(left);
		Ok(())
	}
	fn output_text(&self, reader: capnp::text::Reader<'a>) -> Result<V> {
		self.charge_output_payload(reader.len())?;
		Ok(V::Text(text(reader)?))
	}

	fn node(&self, id: u64) -> Result<node::Reader<'a>> {
		self.nodes.get(&id).copied().ok_or_else(|| "missing schema node".into())
	}
	fn fields(&self, id: u64) -> Result<Vec<field::Reader<'a>>> {
		let node = self.node(id)?;
		let node::Struct(structure) = node.which()? else {
			return Err("expected parameter, result, or alias struct".into());
		};
		if structure.get_is_group() || structure.get_discriminant_count() != 0 {
			return Err("groups and unions are unsupported".into());
		}
		let mut fields: Vec<_> = structure.get_fields()?.into_iter().collect();
		fields.sort_by_key(|field| field.get_code_order());
		Ok(fields)
	}
	fn annotations(
		&self,
		annotations: capnp::struct_list::Reader<'a, annotation::Owned>,
		allowed: &[&str],
	) -> Result<Annotations> {
		let mut result = BTreeMap::new();
		for annotation in annotations {
			if !annotation.get_brand()?.get_scopes()?.is_empty() {
				return Err("generic annotation brands are unsupported".into());
			}
			let name = self
				.annotations
				.get(&annotation.get_id())
				.ok_or("unknown annotation declaration")?;
			if !allowed.contains(&name.as_str()) {
				return Err(format!("unsupported annotation {name} at this location").into());
			}
			let value = match (name.as_str(), annotation.get_value()?.which()?) {
				("module" | "wireName" | "delivery", value::Text(value)) => V::Text(text(value?)?),
				("alias" | "optional" | "nullValue" | "pending" | "direct", value::Void(())) => V::Boolean(true),
				("min" | "max", value::Int64(value)) => V::Integer(value),
				("minBytes" | "maxBytes", value::Uint64(value)) => V::Integer(value.try_into()?),
				_ => return Err(format!("wrong annotation value for {name}").into()),
			};
			if result.insert(name.clone(), value).is_some() {
				return Err("duplicate annotation".into());
			}
		}
		Ok(result)
	}
	fn named_type(&self, id: u64, brand: brand::Reader<'a>) -> Result<V> {
		if !brand.get_scopes()?.is_empty() {
			return Err("generic type brands are unsupported".into());
		}
		let name = self.names.get(&id).ok_or("reference outside the comparison file")?;
		self.charge_output_payload(name.len())?;
		Ok(V::record("ref", vec![V::Text(name.clone())]))
	}

	fn field_type(&self, field: field::Reader<'a>, ann: &Annotations) -> Result<V> {
		let field::Slot(slot) = field.which()? else {
			return Err("group field is unsupported".into());
		};
		if slot.get_had_explicit_default() {
			return Err("explicit defaults are unsupported".into());
		}
		let mut result = match slot.get_type()?.which()? {
			type_::Void(()) => V::symbol(if ann.contains_key("nullValue") {
				"null"
			} else {
				"undefined"
			}),
			type_::Text(()) => V::symbol("string"),
			type_::Int64(()) => V::symbol("integer"),
			type_::AnyPointer(pointer) => {
				let type_::any_pointer::Unconstrained(kind) = pointer.which()? else {
					return Err("generic pointers are unsupported".into());
				};
				if !matches!(kind.which()?, type_::any_pointer::unconstrained::AnyKind(())) {
					return Err("constrained AnyPointer is unsupported".into());
				}
				V::symbol("value")
			}
			type_::Interface(value) => self.named_type(value.get_type_id(), value.get_brand()?)?,
			type_::Struct(value) => self.named_type(value.get_type_id(), value.get_brand()?)?,
			_ => return Err("unsupported field type".into()),
		};
		if ann.contains_key("nullValue") && !matches!(result, V::Symbol(ref name) if name == "null") {
			return Err("nullValue requires Void".into());
		}
		let mut bounds = Vec::new();
		for (source, key, base) in [
			("min", "min", "integer"),
			("max", "max", "integer"),
			("minBytes", "min_bytes", "string"),
			("maxBytes", "max_bytes", "string"),
		] {
			if let Some(value) = ann.get(source) {
				if !matches!(result, V::Symbol(ref name) if name == base) {
					return Err("bound does not match field type".into());
				}
				bounds.push((V::Text(key.into()), value.clone()));
			}
		}
		if !bounds.is_empty() {
			result = V::record("bounded", vec![result, V::Dictionary(bounds)]);
		}
		if ann.contains_key("pending") {
			if !matches!(result, V::Record("ref", _)) && !matches!(result, V::Symbol(ref name) if name == "value") {
				return Err("pending requires a reference or AnyPointer".into());
			}
			result = V::record("promise", vec![result]);
		}
		Ok(result)
	}
}

#[cfg(test)]
mod tests {
	#[test]
	fn unsupported_compiler_request_is_refused_before_projection() {
		let mut message = capnp::message::Builder::new_default();
		let mut request = message.init_root::<capnp::schema_capnp::code_generator_request::Builder>();
		request.reborrow().init_capnp_version().set_major(2);
		assert!(
			super::translate(request.into_reader())
				.err()
				.unwrap()
				.to_string()
				.contains("unsupported compiler request version")
		);
	}
}
