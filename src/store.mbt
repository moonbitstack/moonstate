///|
/// One remembered value: a space, a key inside it, and the value itself.
pub(all) struct Item {
  space : Array[String]
  key : String
  value : Json
}

///|
/// Long-term memory that outlives a thread: spaced key-value pairs with a
/// search over them. A node reaches the store through `Run::store`.
pub(open) trait Store {
  ///|
  async fn get(Self, space : Array[String], key : String) -> Item?
  ///|
  async fn put(Self, space : Array[String], key : String, value : Json) -> Unit
  ///|
  async fn delete(Self, space : Array[String], key : String) -> Unit
  ///|
  /// Items under `space` (or below it), newest first. `query` is matched
  /// against the item's text, `filter` against its top-level object fields.
  async fn search(
    Self,
    space : Array[String],
    query? : String,
    filter? : Map[String, Json],
    limit? : Int32,
  ) -> Array[Item]
}

///|
/// A store that keeps everything in memory, for tests and for short-lived
/// processes.
pub struct MemoryStore {
  items : Map[String, Item]
}

///|
pub fn MemoryStore::new() -> MemoryStore {
  { items: Map([]), }
}

///|
fn item_key(space : Array[String], key : String) -> String {
  let path = StringBuilder()
  for part in space {
    path.write_string(part)
    path.write_char('\u{1f}')
  }
  path.write_char('\u{1e}')
  path.write_string(key)
  path.to_string()
}

///|
fn under_space(item : Item, space : Array[String]) -> Bool {
  guard item.space.length() >= space.length() else { return false }
  for i = 0; i < space.length(); i = i + 1 {
    if item.space[i] != space[i] {
      return false
    }
  }
  true
}

///|
fn matches_filter(item : Item, filter : Map[String, Json]) -> Bool {
  guard item.value is Object(fields) else { return filter.is_empty() }
  for name, wanted in filter {
    match fields.get(name) {
      Some(actual) => if actual != wanted { return false }
      None => return false
    }
  }
  true
}

///|
pub impl Store for MemoryStore with fn get(self, space, key) -> Item? raise {
  self.items.get(item_key(space, key))
}

///|
pub impl Store for MemoryStore with fn put(self, space, key, value) -> Unit raise {
  self.items[item_key(space, key)] = { space, key, value, }
}

///|
pub impl Store for MemoryStore with fn delete(self, space, key) -> Unit raise {
  self.items.remove(item_key(space, key))
}

///|
pub impl Store for MemoryStore with fn search(
  self,
  space,
  query?,
  filter?,
  limit?,
) -> Array[Item] raise {
  let wanted = match limit {
    Some(limit) => limit
    None => 10
  }
  let found = []
  for _, item in self.items {
    if !under_space(item, space) {
      continue
    }
    match query {
      Some(text) => if !@moonjson.dumps(item.value).contains(text) { continue }
      None => ()
    }
    match filter {
      Some(filter) => if !matches_filter(item, filter) { continue }
      None => ()
    }
    found.push(item)
  }
  if found.length() > wanted {
    let cut = []
    for index = 0; index < wanted; index = index + 1 {
      cut.push(found[index])
    }
    cut
  } else {
    found
  }
}

///|
pub extend MemoryStore with Store::{get, put, delete, search}
