///|
/// A graph of one node: the entry is the node itself, and a run of it is a
/// single superstep.
async test "a single node graph runs once" {
  let graph = counter_builder()
    .node("only", (_state, _run) => [@moonstate.Write(count(7, "only"))])
    .compile("single") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(1)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out, counter(7, ["only"]))
}

///|
/// Fan-out: two nodes leave the same node, so both run in the same superstep,
/// and their writes fold in the order the edges were declared.
async test "parallel branches run in one superstep and merge in edge order" {
  let order : Array[String] = []
  let graph = counter_builder()
    .entry("start")
    .node("start", (_state, _run) => [])
    .node("slow", (_state, _run) => {
      order.push("slow")
      [@moonstate.Write(add("slow"))]
    })
    .node("quick", (_state, _run) => {
      order.push("quick")
      [@moonstate.Write(add("quick"))]
    })
    .edge("start", "slow")
    .edge("start", "quick")
    .compile("fan") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["slow", "quick"])
}

///|
/// A node may pick the next node itself instead of leaving through its edges.
async test "goto overrides the declared edges" {
  let graph = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => {
      [@moonstate.Write(add("a")), @moonstate.Goto("c")]
    })
    .node("b", (_state, _run) => [@moonstate.Write(add("b"))])
    .node("c", (_state, _run) => [@moonstate.Write(add("c"))])
    .edge("a", "b")
    .edge("b", "c")
    .compile("goto") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["a", "c"])
}

///|
/// `Send` gives each task its own input state: one node fans out over three
/// values, and each of the three writes into the same merged state.
async test "send maps one node over several inputs" {
  let graph = counter_builder()
    .entry("fan")
    .node("fan", (_state, _run) => {
      [
        @moonstate.Send("work", counter(1, ["one"])),
        @moonstate.Send("work", counter(2, ["two"])),
        @moonstate.Send("work", counter(3, ["three"])),
      ]
    })
    .node("work", (state, _run) => [@moonstate.Write(count(state.n * 10, "w"))])
    .routed("work")
    .compile("send") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.n, 30)
  assert_eq(out.log, ["w", "w", "w"])
}

///|
/// A branch routes on the state as merged at the end of the superstep, so it sees
/// what the node it follows wrote in that same superstep.
async test "a branch routes on the merged state" {
  let graph = counter_builder()
    .entry("check")
    .node("check", (_state, _run) => [@moonstate.Write(count(5, "check"))])
    .node("big", (_state, _run) => [@moonstate.Write(add("big"))])
    .node("small", (_state, _run) => [@moonstate.Write(add("small"))])
    .branch("check", state => if state.n > 3 { ["big"] } else { ["small"] })
    .compile("branch") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["check", "big"])
}

///|
/// A join is a gate: it fires only when every upstream node ran in the same
/// superstep. Here `b` runs one superstep after `a`, so the gate stays shut.
async test "a join does not fire when its upstream nodes are split across supersteps" {
  let graph = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => [@moonstate.Write(add("a"))])
    .node("b", (_state, _run) => [@moonstate.Write(add("b"))])
    .node("gated", (_state, _run) => [@moonstate.Write(add("gated"))])
    .edge("a", "b")
    .edge("a", "gated")
    .join(["a", "b"], "gated")
    .compile("join") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["a", "b"])
}

///|
/// With both upstream nodes in the same superstep, the join fires exactly once.
async test "a join fires once when every upstream node ran" {
  let graph = counter_builder()
    .entry("start")
    .node("start", (_state, _run) => [])
    .node("a", (_state, _run) => [@moonstate.Write(add("a"))])
    .node("b", (_state, _run) => [@moonstate.Write(add("b"))])
    .node("gated", (_state, _run) => [@moonstate.Write(add("gated"))])
    .edge("start", "a")
    .edge("start", "b")
    .join(["a", "b"], "gated")
    .compile("join") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["a", "b", "gated"])
}

///|
async test "a cycle stops at the step limit" {
  let ticks = Ref(0)
  let graph = counter_builder()
    .entry("loop")
    .node("loop", (state, _run) => {
      ticks.val = ticks.val + 1
      [@moonstate.Write(count(state.n + 1, "tick"))]
    })
    .node("stop", (_state, _run) => [])
    .branch("loop", _state => ["loop"])
    .edge("loop", "stop")
    .compile("cycle", limit=3) catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let message = try {
    graph.run(seed(0)) |> ignore
    "no failure"
  } catch {
    @moonstate.StepLimit(limit~) => "limit " + limit.to_string()
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "limit 3")
  // The bound is on supersteps, so the node ran as many times as the limit
  // allows: not one fewer, not one more.
  assert_eq(ticks.val, 3)
}

///|
/// A node that cancels the run finishes, and the thread stops at the next
/// superstep boundary instead of being cut off inside a node.
async test "a cancelled run stops at the superstep boundary" {
  let reached : Array[String] = []
  let graph = counter_builder()
    .entry("first")
    .node("first", (_state, run) => {
      reached.push("first")
      run.cancel()
      [@moonstate.Write(add("first"))]
    })
    .node("second", (_state, _run) => {
      reached.push("second")
      [@moonstate.Write(add("second"))]
    })
    .edge("first", "second")
    .compile("cancel") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let message = try {
    graph.run(seed(0)) |> ignore
    "no failure"
  } catch {
    @moonstate.Cancelled(..) => "cancelled"
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "cancelled")
  assert_eq(reached, ["first"])
}

///|
/// A node that raises is retried as often as its policy says, and the run fails
/// with the number of tries the policy allowed.
async test "a retry policy is honoured before the run fails" {
  let tries = Ref(0)
  let graph = counter_builder()
    .entry("flaky")
    .node(
      "flaky",
      (_state, _run) => {
        tries.val = tries.val + 1
        raise Failure::Failure("not yet")
      },
      retry=@moonstate.Retry::{ attempts: 3, delay: 0, },
    )
    .compile("retry") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let message = try {
    graph.run(seed(0)) |> ignore
    "no failure"
  } catch {
    @moonstate.NodeFailed(node~, ..) => node + " after " + tries.val.to_string()
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "flaky after 3")
}

///|
/// A node that fails once and then succeeds does not fail the run.
async test "a retried node that recovers does not fail the run" {
  let tries = Ref(0)
  let graph = counter_builder()
    .entry("flaky")
    .node(
      "flaky",
      (_state, _run) => {
        tries.val = tries.val + 1
        if tries.val == 1 {
          raise Failure::Failure("first try")
        }
        [@moonstate.Write(add("done"))]
      },
      retry=@moonstate.Retry::{ attempts: 2, delay: 0, },
    )
    .compile("retry") catch {
      refused => fail("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["done"])
  assert_eq(tries.val, 2)
}
