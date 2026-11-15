// What the graph keeps between nodes. A write replaces `label`, adds to `n` and appends to `log`.

///|
#state.patch
#derive(@json.ToJson, @json.FromJson)
struct Counter {
  #state.add
  n : Int32
  #state.append
  log : Array[String]
  label : String
}

///|
pub extend Counter with @json.ToJson::{to_json}

///|
pub extend Counter with @json.FromJson::{from_json}
