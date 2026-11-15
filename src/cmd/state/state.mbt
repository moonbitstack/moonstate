///|
/// `#state.patch` on a record, turned into its patch type and its merge.
priv struct State {}

///|
impl @gen.Generator for State with fn name(_) {
  "moonstate"
}

///|
/// Where `attr` is written, as `file:line:column`.
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
/// How one field takes a write: replaced, appended to, added to, or folded by a function of the
/// program's own.
priv enum Reducer {
  Replace
  Append
  Add
  With(String)
}

///|
/// The reducer a field's annotations name. Two on one field is a mistake, not a choice.
fn reducer_of(field : @gen.Field, file : String) -> Reducer raise {
  let found = @attr.under(field.attrs, "state")
  match found {
    [] => Replace
    [attr] =>
      match @attr.name_of(attr) {
        Some("state.append") => Append
        Some("state.add") => Add
        Some("state.with") => {
          let args = @attr.Spec::new("state.with")
            .positional("reducer", Path)
            .bind(attr)
          guard args.get("reducer") is [Ident(name)] else {
            fail(
              "\{at(attr, file)}: `#state.with` names the function that merges",
            )
          }
          With(if name.contains(".") { "@" + name } else { name })
        }
        _ => fail("\{at(attr, file)}: not a field reducer of moonstate")
      }
    [_, second, ..] => fail("\{at(second, file)}: a field takes one reducer")
  }
}

///|
/// The value field `name` has after `patch` is merged into `state`.
fn merged(name : String, reducer : Reducer) -> String {
  let old = "state.\{name}"
  let new = match reducer {
    Replace => "value"
    Append => "\{old} + value"
    Add => "\{old} + value"
    With(f) => "\{f}(\{old}, value)"
  }
  "\{name}: match patch.\{name} { Some(value) => \{new}; None => \{old} }"
}

///|
/// The patch type and the merge for the record `name`.
fn patch_of(
  attr : @attribute.Attribute,
  name : String,
  fields : Array[@gen.Field],
  public : Bool,
  file : String,
) -> String raise {
  guard @attr.name_of(attr) is Some("state.patch") else {
    fail("\{at(attr, file)}: a record takes `#state.patch`")
  }
  let patch = name + "Patch"
  let merge = "merge_" + name.to_lower()
  let declared = []
  let assigned = []
  for field in fields {
    declared.push("  \{field.name} : \{field.ty}?")
    assigned.push("    " + merged(field.name, reducer_of(field, file)))
  }
  let (vis_type, vis_fn) = if public { ("pub(all) ", "pub ") } else { ("", "") }
  [
    "#derive(@json.ToJson, @json.FromJson)",
    "\{vis_type}struct \{patch} {",
    declared.join("\n"),
    "}",
    "",
    "pub extend \{patch} with @json.ToJson::{to_json}",
    "",
    "pub extend \{patch} with @json.FromJson::{from_json}",
    "",
    "\{vis_fn}fn \{merge}(state : \{name}, patch : \{patch}) -> \{name} {",
    "  {",
    assigned.join(",\n"),
    "  }",
    "}",
  ].join("\n")
}

///|
impl @gen.Generator for State with fn generate(_, decls) {
  let parts = []
  for decl in decls {
    let found = @attr.under(decl.attrs(), "state")
    guard found is [first, ..] else { continue }
    guard decl is Struct(name~, fields~, public~, file~, ..) else {
      fail("\{at(first, decl.file())}: `#state.patch` goes on a record")
    }
    for attr in found {
      parts.push(patch_of(attr, name, fields, public, file))
    }
  }
  @quote.items(parts.join("\n\n")).render()
}
