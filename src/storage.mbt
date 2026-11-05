// Agent state storage (Koog `AIAgentStorage`): the key-value store an agent's strategy graph uses to
// pass typed values between nodes. Koog keys entries by a reflection-carrying `AIAgentStorageKey<T>`
// and holds a heterogeneous `Map<Key, Any>`; MoonBit has neither reflection nor a dynamic `Any`, so
// this mirrors Koog's own serialized backing store — a `String -> Json` map — with the value type
// chosen at the call site through `ToJson` on `set` and `FromJson` on `get`.
// Source: agents/agents-core/.../entity/AIAgentStorageAPI.kt + AIAgentStorageImpl.kt.

///|
/// A per-agent key-value store of Json-serialized values.
pub struct AgentStorage {
  entries : Map[String, Json]
}

///|
/// A fresh empty store.
pub fn AgentStorage::new() -> AgentStorage {
  { entries: {}, }
}

///|
/// Serialize `value` and store it under `key`, replacing any existing value.
pub fn[T : ToJson] AgentStorage::set(
  self : AgentStorage,
  key : String,
  value : T,
) -> Unit {
  self.entries[key] = value.to_json()
}

///|
/// The value stored under `key`, deserialized to `T`, or `None` if the key is absent or its stored
/// Json does not decode to `T`.
pub fn[T : @json.FromJson] AgentStorage::get(
  self : AgentStorage,
  key : String,
) -> T? {
  guard self.entries.get(key) is Some(json) else { return None }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
/// Whether a value is stored under `key`.
pub fn AgentStorage::contains(self : AgentStorage, key : String) -> Bool {
  self.entries.get(key) is Some(_)
}

///|
/// Remove `key`; returns whether it was present.
pub fn AgentStorage::remove(self : AgentStorage, key : String) -> Bool {
  if self.entries.get(key) is Some(_) {
    self.entries.remove(key)
    true
  } else {
    false
  }
}

///|
/// Remove every entry.
pub fn AgentStorage::clear(self : AgentStorage) -> Unit {
  self.entries.clear()
}

///|
/// The number of stored entries.
pub fn AgentStorage::size(self : AgentStorage) -> Int32 {
  self.entries.length()
}

///|
/// A Json snapshot of the whole store — every entry as a field of a Json object (Koog's
/// `toSerializedMap`). This is what a checkpoint persists, so it has to be a value taken at
/// this instant: `Json::object` wraps the map it is handed rather than copying it, and handing
/// over `entries` would file a checkpoint that keeps changing as the run writes on, until an
/// early checkpoint read back the run's final state.
pub fn AgentStorage::snapshot(self : AgentStorage) -> Json {
  let taken : Map[String, Json] = Map([])
  for key, value in self.entries {
    taken[key] = value
  }
  Json::object(taken)
}

///|
/// Replace the store's contents from a `snapshot` Json object, for restoring from a checkpoint.
pub fn AgentStorage::restore(self : AgentStorage, snapshot : Json) -> Unit {
  self.entries.clear()
  if snapshot is Object(obj) {
    for key, value in obj {
      self.entries[key] = value
    }
  }
}
