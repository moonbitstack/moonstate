///|
/// How often a node is tried before its failure ends the run, and how long to
/// wait between tries. `attempts` counts the first try: `attempts` of 1 means no
/// retry at all.
pub(all) struct Retry {
  attempts : Int32
  delay : Int32
}

///|
/// Three tries with no pause, the default a durable workflow wants for a step
/// that talks to something outside the process.
pub let retry : Retry = { attempts: 3, delay: 0, }
