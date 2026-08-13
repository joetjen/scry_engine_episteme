# scry_engine_episteme

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation for the `logic` kind (lang_spec.md §8.4), backed by
[Episteme](https://hex.pm/packages/episteme) -- a genuine Prolog-like
resolution engine and clause database for Elixir -- instead of
[`scry_logic`](https://github.com/joetjen/scry_logic)'s own hand-rolled
reference `conn` (facts and rules written directly as Elixir closures).
No separate driver dependency the way most other `scry_engine_*`
packages have one: Episteme *is* the backend, logic database included,
not a thin client over something else (impl_spec.md §6).

Source: <https://github.com/joetjen/scry_engine_episteme>. Specs live
in the separate [`scry`](https://github.com/joetjen/scry) repository;
the behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
alias Episteme.Database
alias Episteme.Term.Compound

db =
  Database.new()
  |> Database.add_fact(%Compound{name: :parent, args: ["tom", "bob"]})
  |> Database.add_fact(%Compound{name: :parent, args: ["bob", "ann"]})

{:ok, query} = Scry.Core.parse(~s(SELECT parent("tom", Y) { Y }))
{:ok, cursor} = Scry.Engine.Episteme.run(query, db)
Scry.Core.Cursor.to_list(cursor)
# => [%{"Y" => "bob"}]
```

`conn` is a plain `Episteme.Database.t()` -- build it directly with
`Episteme.Database.add_fact/2`/`add_clause/2`, or via
`Episteme.Database.consult_forms/2` for a front-end with its own
concrete syntax (e.g. [Aletheia](https://hex.pm/packages/aletheia)'s
real Prolog reader). A relation you want to exist but currently has no
facts needs `Episteme.Database.declare_dynamic/3` called on it first --
see "What's genuinely different from `scry_logic`'s reference engine"
below.

### What gets executed here vs. delegated

`Scry.Engine.Episteme.execute/3` resolves the query's own call-shaped
source (`ancestor(X, "bob")`) and any `WHERE`-embedded goal calls
(`age(X) > 30`) into a combined `Episteme.Term.Compound` goal, runs it
via `Episteme.query/2`, and turns each solution into a row. Everything
else -- ordinary `WHERE`, `GROUP BY`, aggregates, `ORDER BY`, `LIMIT`,
projection -- is handed to `Scry.Core.QueryOps.run_flat/3` unchanged,
the same "build special source rows, delegate the rest" shape
`scry_search`/`scry_document`/`scry_graph` already use.

### What's genuinely different from `scry_logic`'s reference engine

Two real behavioral divergences, both found by actually running
queries against Episteme rather than assumed from its docs:

- **An undefined predicate is a `query_error`, not a silent empty
  result.** `Scry.Logic.Executor`'s own hand-rolled `conn` treats a
  relation it has no clauses for as zero solutions. Episteme's own
  resolution engine raises a real ISO `existence_error(procedure,
  name/arity)` for a genuinely undefined `{name, arity}` -- this
  module surfaces that honestly as `{:error, {:query_error,
  {:existence_error, :procedure, {name, arity}}}}`. A relation that
  *is* defined but simply has no matching clause for the arguments at
  hand still just fails (zero solutions), same as always. Because
  "zero facts ever added" and "never defined" look identical to a
  plain `Episteme.Database.t()`, a relation you want to be defined but
  currently empty needs `Episteme.Database.declare_dynamic/3` called
  on it explicitly first.
- **A recursive rule needs no special authoring convention.**
  `Scry.Logic.Executor`'s own moduledoc has a load-bearing section on
  wrapping a recursive clause's self-call in an extra closure, or
  `Ichor.Backtrack`'s eager disjunction-building recurses infinitely
  before any bindings exist. Episteme's own `Episteme.Engine` builds
  each clause's goal lazily, at call time, so an ordinary recursive
  rule (`ancestor(X, Y) :- parent(X, Y). ancestor(X, Y) :- parent(X,
  Z), ancestor(Z, Y).`), written the plain way via
  `Database.add_clause/2`, terminates correctly with no extra wrapper.

## Installation

```elixir
def deps do
  [
    {:scry_engine_episteme, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_episteme>.
