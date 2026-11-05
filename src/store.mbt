// This package tracks Koog **0.7.3**, not 1.1.1 like the rest of the repo. The
// `Concept` / `Fact` / `MemorySubject` / `MemoryScope` / `AgentMemoryProvider` model
// transcribed here was removed upstream by 0.8.0, where memory became `ChatMemory`
// (chat-history providers) and `LongTermMemory` (`MemoryRecord` + ingestion and
// retrieval). Re-anchoring means rewriting this package, not renaming it.

///|
/// Whether a concept holds one fact or many (Koog `FactType`).
pub(all) enum FactType {
  Single
  Multiple
} derive(Eq, Debug)

///|
/// A concept the agent remembers facts about: a short `keyword`, a `description`
/// the model is shown, and whether it carries one fact or many. Transcribed from
/// the koog `Concept` data class.
pub(all) struct Concept {
  keyword : String
  description : String
  fact_type : FactType
} derive(Eq, Debug)

///|
/// A fact about a concept, timestamped when captured (Koog's sealed `Fact`:
/// `SingleFact` carries one `value`, `MultipleFacts` a list of `values`). The
/// timestamp is caller-supplied — MoonBit has no ambient clock — the explicit
/// equivalent of Koog threading a `Clock` into fact retrieval.
pub(all) enum Fact {
  SingleFact(concept~ : Concept, value~ : String, timestamp~ : Int64)
  MultipleFacts(concept~ : Concept, values~ : Array[String], timestamp~ : Int64)
} derive(Eq, Debug)

///|
/// The concept a fact is about, whichever variant it is.
pub fn Fact::concept(self : Fact) -> Concept {
  match self {
    SingleFact(concept~, ..) => concept
    MultipleFacts(concept~, ..) => concept
  }
}

///|
/// Who or what a fact is about (Koog `MemorySubject`): a `name`, and a `priority`
/// for ordering when subjects overlap. The predefined subjects mirror Koog's.
pub(all) struct MemorySubject {
  name : String
  priority : Int32
} derive(Eq, Debug)

///|
pub let subject_everything : MemorySubject = {
  name: "everything",
  priority: 0,
}

///|
pub let subject_user : MemorySubject = { name: "user", priority: 1, }

///|
pub let subject_machine : MemorySubject = { name: "machine", priority: 2, }

///|
pub let subject_organization : MemorySubject = {
  name: "organization",
  priority: 3,
}

///|
/// How widely a fact is shared (Koog `MemoryScope`): to a single agent, a single
/// feature, the whole product, or across products.
pub(all) enum MemoryScope {
  ScopeAgent(String)
  ScopeFeature(String)
  ScopeProduct
  ScopeCrossProduct
} derive(Eq, Debug)

///|
/// The storage key for a `(subject, scope)` bucket.
fn bucket_key(subject : MemorySubject, scope : MemoryScope) -> String {
  let s = match scope {
    ScopeAgent(a) => "agent:" + a
    ScopeFeature(f) => "feature:" + f
    ScopeProduct => "product"
    ScopeCrossProduct => "cross-product"
  }
  s + "|" + subject.name
}

///|
/// The save/load contract for agent memory (Koog `AgentMemoryProvider`): store a
/// fact under a subject and scope, load a concept's facts back, or load everything
/// in a bucket.
pub(open) trait MemoryProvider {
  fn save(Self, fact : Fact, subject : MemorySubject, scope : MemoryScope) -> Unit
  fn load(Self, concept : Concept, subject : MemorySubject, scope : MemoryScope) -> Array[
    Fact,
  ]
  fn load_all(Self, subject : MemorySubject, scope : MemoryScope) -> Array[Fact]
}

///|
/// An in-memory `MemoryProvider`: facts kept in a map keyed by `(scope, subject)`.
/// The faithful equivalent of Koog's `LocalFileMemoryProvider` without the file
/// backend — enough to run and test the memory contract in process.
pub struct InMemoryProvider {
  store : Map[String, Array[Fact]]
}

///|
/// An empty in-memory provider.
pub fn InMemoryProvider::new() -> InMemoryProvider {
  { store: Map([]), }
}

///|
pub impl MemoryProvider for InMemoryProvider with fn save(
  self,
  fact,
  subject,
  scope,
) {
  let key = bucket_key(subject, scope)
  match self.store.get(key) {
    Some(facts) => facts.push(fact)
    None => self.store[key] = [fact]
  }
}

///|
pub impl MemoryProvider for InMemoryProvider with fn load(
  self,
  concept,
  subject,
  scope,
) {
  let out : Array[Fact] = []
  match self.store.get(bucket_key(subject, scope)) {
    Some(facts) =>
      for f in facts {
        if f.concept().keyword == concept.keyword {
          out.push(f)
        }
      }
    None => ()
  }
  out
}

///|
pub impl MemoryProvider for InMemoryProvider with fn load_all(
  self,
  subject,
  scope,
) {
  match self.store.get(bucket_key(subject, scope)) {
    Some(facts) => [..facts]
    None => []
  }
}

///|
pub extend Concept with Debug::{to_repr}

///|
pub extend Concept with Eq::{not_equal, equal}

///|
pub extend Fact with Debug::{to_repr}

///|
pub extend Fact with Eq::{not_equal, equal}

///|
pub extend FactType with Debug::{to_repr}

///|
pub extend FactType with Eq::{not_equal, equal}

///|
pub extend InMemoryProvider with MemoryProvider::{save, load_all, load}

///|
pub extend MemoryScope with Debug::{to_repr}

///|
pub extend MemoryScope with Eq::{not_equal, equal}

///|
pub extend MemorySubject with Debug::{to_repr}

///|
pub extend MemorySubject with Eq::{not_equal, equal}
