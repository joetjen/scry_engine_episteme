defmodule Scry.Engine.Episteme do
  @moduledoc """
  `Scry.Core.EngineBehaviour` for the `logic` variant,
  backed by a real Prolog-like resolution engine
  ([Episteme](https://hex.pm/packages/episteme)) instead of
  `scry_logic`'s own hand-rolled reference `conn`
  (`Scry.Logic.Executor`, `%{{name, arity} => [clause_fun]}`, facts
  and rules written directly as Elixir closures). `conn` here is a
  plain `Episteme.Database.t()` -- built via `Episteme.Database.new/1`
  plus `add_fact/2`/`add_clause/2`/`consult_forms/2`, the same
  database a caller queries directly with `Episteme.query/2` for
  anything outside Scry. No separate driver segment -- episteme *is*
  the backend, logic database included, not a thin client over
  something else.

  `SELECT ancestor(X, "bob") WHERE age(X) > 30 { X }` becomes: resolve
  the call-shaped source (`%Scry.Core.Query{}.goal_args`) into an
  `Episteme.Term.Compound` goal, find and conjoin any further goal
  calls hiding inside `WHERE` (`age(X)`, arity-plus-one'd into a fresh
  output variable when it's being compared rather than used bare --
  this module's own `extract_where_goals/4`, structurally the same
  rewrite `Scry.Logic.Executor` already does), run the combined goal
  via `Episteme.query/2`, and turn each solution's own variable
  bindings into an ordinary row -- then hand the rest (any remaining
  plain `WHERE`, `GROUP BY`, `ORDER BY`, `LIMIT`, projection) to
  `Scry.Core.QueryOps.run_flat/3`, unchanged, exactly the "build
  special source rows, delegate everything else" shape `scry_logic`/
  `scry_search`/`scry_document`/`scry_graph` already established.

  ## A real, not just hypothetical, behavioral divergence from `scry_logic`'s own reference engine

  `Scry.Logic.Executor`'s own moduledoc documents its "a relation this
  module can't find any clauses for simply has zero solutions (fails
  silently)" choice as "reasonable for a reference/test engine, worth
  reconsidering for a real backend adapter later." This is that real
  backend, and Episteme's own `Episteme.Engine.solve_user_predicate/4`
  answers differently, on purpose: calling an *undefined* predicate
  (never `add_fact`/`add_clause`d for that `{name, arity}`) raises a
  real ISO `existence_error(procedure, name/arity)`, not a silent
  empty result -- this module surfaces that as `{:error, {:query_error,
  {:existence_error, :procedure, {name, arity}}}}` rather than papering
  over it, honest with what the real backend actually does. A relation
  that *is* defined but has no matching clause for these particular
  arguments still simply fails (zero solutions), same as always --
  the divergence is specifically "never defined at all" vs. "defined,
  no match." Found the hard way, not designed in up front: a relation
  with zero facts ever added is indistinguishable from an undefined one
  in a plain `Episteme.Database.t()` (neither has a stored entry for
  its own `{name, arity}`) -- a caller that wants "defined, currently
  empty" (so a query against it returns zero rows rather than erroring)
  has to say so explicitly via `Episteme.Database.declare_dynamic/3`
  before this module ever sees it, the same real-Prolog `:- dynamic
  foo/1.` declaration that function is named after.

  ## A second real divergence, found deliberately checking rather than assuming: recursive rules need no special authoring convention here

  `Scry.Logic.Executor`'s own moduledoc has a long, load-bearing
  section on why a `conn`-supplied recursive relation must wrap its own
  self-call in an extra closure, or `Ichor.Backtrack`'s own eager
  disjunction-building recurses infinitely at goal-*construction* time
  before any bindings exist. That gotcha is specific to hand-writing
  clauses directly as `[term()] -> Ichor.Backtrack.goal()` functions --
  Episteme's own `Episteme.Engine` stores a rule as an ordinary
  `{head, body}` clause term and only builds each clause's own goal
  *lazily*, inside `try_clauses/4`, once a real call actually reaches
  it (confirmed directly against `Episteme.Engine`'s source, not
  assumed from the outside). A ground-truth-recursive rule
  (`ancestor(X, Y) :- parent(X, Y). ancestor(X, Y) :- parent(X, Z),
  ancestor(Z, Y).`), built the ordinary way via `Database.add_clause/2`
  with no extra laziness wrapper of any kind, terminates correctly --
  this module's own test suite proves it against the identical
  family-tree domain `scry_test_logic` uses, specifically so the two
  can be compared side by side.

  ## Term representation

  Episteme's own atomic term classes already line up with every
  literal Scry's grammar can hand a goal argument: a Scry string
  literal is a plain Elixir binary, which Episteme treats as "a real
  Prolog string" (its own distinct term class, not a code list) --
  and a number/boolean/`nil` literal is already the same raw Elixir
  value in both systems (Elixir's `true`/`false`/`nil` *are* atoms).
  No translation step is needed for any of these; they cross the
  boundary as themselves. A `{:field, [name]}` argument becomes an
  `Episteme.Term.Var.t()`, memoized in a `%{name => Var.t()}` map
  threaded through goal resolution so that two occurrences of the same
  query-level variable name -- in the source call, in a `WHERE`-
  embedded goal, or both -- share the same `Var.t()` (identity keyed
  by `ref`, not by name, unlike `Scry.Logic.Executor`'s own bare
  `{:var, name}` tuples) and therefore genuinely unify together rather
  than being coincidentally-named strangers.

  ## Stated scope limits, not silently mishandled

  Identical to `Scry.Logic.Executor`'s own (the grammar-level ones are
  facts about `priv/grammar.aether`, not something either executor
  chooses): `WHERE`-embedded goal calls are only recognized as one side
  of a `{:cmp, ...}` comparison; `%Scry.Core.CombinedQuery{}` (`UNION`/
  `INTERSECT`/`EXCEPT`) is declined outright; a goal argument must
  resolve to a plain ground value, an external `$param`, or a bare
  field reference; `query.with_bindings`/a correlated nested `SELECT`
  as a `logic` query's own source is not handled. One further,
  Episteme-specific scope limit: a solution binding a query variable to
  a non-atomic term (a compound or a list, e.g. a stored fact whose own
  argument is itself structured) surfaces as that term's own
  `Episteme.Term.to_text/1` rendering in the output row, rather than as
  a nested Elixir structure a downstream `Scry.Core.QueryOps` predicate
  could meaningfully compare against -- Scry's own row shape has no
  place for a nested logic term, and no worked example needs one.

  ## Deliberately not guarded against: unbounded atom creation from arbitrary query text

  Every predicate name (the query's own source functor, and any
  `WHERE`-embedded goal call name) has to become an Elixir atom before
  it can be an `Episteme.Term.Compound{}` functor -- but `String.to_atom/1`
  on arbitrary, externally-supplied text is a real, well-known atom-
  table-exhaustion vector (the table is process-global and never
  garbage collected), the same class of risk `scry_engine_exqlite`'s
  own identifier-safety check exists to close for SQL. This module
  closes it the same way, structurally: `String.to_existing_atom/1`,
  rescued -- a name that was never an atom anywhere in this running
  node cannot possibly be a defined predicate either (defining one via
  `add_fact`/`add_clause` requires the atom to already exist in the
  Elixir source that built the database), so a lookup miss here is
  answered with the exact same `existence_error` shape a genuinely
  *defined*-but-wrong-arity lookup gets from Episteme itself, never a
  fresh atom minted just to ask the question.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Episteme.Database
  alias Episteme.Term
  alias Episteme.Term.{Compound, Var}
  alias Scry.Core.{CombinedQuery, Cursor, Query, QueryOps}

  # Deliberately duplicated from `Scry.Core.QueryOps`'s own private
  # `@aggregate_names ++ @cast_names` (not exposed publicly by that
  # module) -- see `Scry.Logic.Executor`'s own identical attribute for
  # the full reasoning; kept in sync with it by hand.
  @known_call_names ~w(
    sum avg count min max stddev_samp stddev_pop var_samp var_pop percentile rate
    string int exact inexact json
  )

  @doc """
  Runs `query_or_combined` against `db`, wrapping the result in a
  `Scry.Core.Cursor.t()` -- the same `execute/3`-then-`Cursor.new/1`
  shape `Scry.Logic.Executor.run/3` and `Scry.Search.Executor.run/3`
  already use.
  """
  @spec run(Query.t() | CombinedQuery.t(), Database.t(), %{String.t() => term()}) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query_or_combined, db, params \\ %{}) do
    with {:ok, rows} <- execute(db, query_or_combined, params) do
      {:ok, Cursor.new(rows)}
    end
  end

  @impl true
  def execute(_db, %CombinedQuery{}, _params) do
    {:error, {:unsupported, {:construct, :combined_query}}}
  end

  @impl true
  def execute(_db, %Query{goal_args: nil}, _params) do
    {:error, {:unsupported, {:construct, :non_goal_source}}}
  end

  def execute(db, %Query{} = query, params) do
    with {:ok, source_args, var_map} <- resolve_args(query.goal_args, params, %{}),
         {:ok, source_goal} <- goal_for_functor(List.last(query.source), source_args),
         {:ok, rewritten_wheres, extra_goals, _var_map} <-
           extract_where_goals(query.wheres, params, var_map) do
      combined_goal = Enum.reduce(extra_goals, source_goal, &and_goal(&2, &1))

      case Episteme.query(combined_goal, db) do
        {:ok, solutions} ->
          rows = Enum.map(solutions, &normalize_row/1)
          QueryOps.run_flat(rows, %{query | wheres: rewritten_wheres}, params)

        {:error, thrown} ->
          {:error, {:query_error, thrown}}
      end
    end
  end

  @impl true
  def capabilities(_db) do
    %{aggregates: MapSet.new(~w(sum avg count min max)), window_functions: false}
  end

  defp and_goal(a, b), do: %Compound{name: :and, args: [a, b]}

  # ---- goal construction ---------------------------------------------------

  defp goal_for_functor(name, []) do
    case safe_atom(name) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:query_error, {:existence_error, :procedure, {name, 0}}}}
    end
  end

  defp goal_for_functor(name, args) do
    case safe_atom(name) do
      {:ok, atom} -> {:ok, %Compound{name: atom, args: args}}
      :error -> {:error, {:query_error, {:existence_error, :procedure, {name, length(args)}}}}
    end
  end

  # A name that was never an Elixir atom anywhere in this running node
  # cannot be a defined Episteme predicate either -- see this module's
  # own moduledoc ("Deliberately not guarded against" section, despite
  # the name, is the *rejected* alternative it explains why this
  # function avoids).
  @spec safe_atom(String.t()) :: {:ok, atom()} | :error
  defp safe_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # ---- goal argument resolution ---------------------------------------------

  # Resolves a list of `expr()` goal arguments (source `goal_args`, or a
  # `WHERE`-embedded call's own args) into `{terms, var_map}` -- a bare
  # `{:field, path}` becomes (or reuses) an `Episteme.Term.Var.t()`,
  # memoized in `var_map` by name so repeated occurrences of the same
  # query-level variable share one `Var.t()` and genuinely unify;
  # `{:param, name}` resolves against `params`; anything else that's
  # already a plain literal (string/number/boolean/nil/`%Rational{}`)
  # passes through unchanged (this module's own moduledoc: "Term
  # representation"). Any other `expr()` shape (arithmetic, a nested
  # call, `{:dot, ...}`, ...) is declined.
  defp resolve_args(args, params, var_map) do
    Enum.reduce_while(args, {:ok, [], var_map}, fn arg, {:ok, terms, vm} ->
      case resolve_arg(arg, params, vm) do
        {:ok, term, new_vm} -> {:cont, {:ok, terms ++ [term], new_vm}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_arg({:field, [name]}, _params, var_map) do
    case Map.fetch(var_map, name) do
      {:ok, var} -> {:ok, var, var_map}
      :error -> mint_var(name, var_map)
    end
  end

  defp resolve_arg({:param, name}, params, var_map) do
    case Map.fetch(params, name) do
      {:ok, value} -> {:ok, value, var_map}
      :error -> {:error, {:query_error, {:missing_param, name}}}
    end
  end

  defp resolve_arg(literal, _params, var_map)
       when is_binary(literal) or is_number(literal) or is_boolean(literal) or is_nil(literal) or
              is_struct(literal, Scry.Core.Rational) do
    {:ok, literal, var_map}
  end

  defp resolve_arg(other, _params, _var_map),
    do: {:error, {:unsupported, {:goal_argument, other}}}

  defp mint_var(name, var_map) do
    var = Term.new_var(name)
    {:ok, var, Map.put(var_map, name, var)}
  end

  # ---- WHERE-embedded goal extraction ---------------------------------------

  # Walks `wheres` (an AND-ed list of predicates, each possibly nested
  # `{:and, ...}`/`{:or, ...}`/`{:not, ...}`), finding every `{:cmp, op,
  # lhs, rhs}` where one side is a wildcard call (`name` not in
  # `@known_call_names`). Structurally identical to `Scry.Logic.
  # Executor.extract_where_goals/2`; see that module's own moduledoc
  # for why the call can only ever appear on `lhs`, never `rhs`.
  defp extract_where_goals(wheres, params, var_map) do
    wheres
    |> Enum.reduce_while({:ok, [], [], var_map, 0}, fn predicate,
                                                       {:ok, preds, goals, vm, counter} ->
      case rewrite_predicate(predicate, params, vm, counter) do
        {:ok, new_pred, new_goals, new_vm, new_counter} ->
          {:cont, {:ok, preds ++ [new_pred], goals ++ new_goals, new_vm, new_counter}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, preds, goals, vm, _counter} -> {:ok, preds, goals, vm}
      {:error, _} = err -> err
    end
  end

  defp rewrite_predicate({:and, left, right}, params, vm, counter),
    do: rewrite_combinator(:and, left, right, params, vm, counter)

  defp rewrite_predicate({:or, left, right}, params, vm, counter),
    do: rewrite_combinator(:or, left, right, params, vm, counter)

  defp rewrite_predicate({:not, inner}, params, vm, counter) do
    with {:ok, new_inner, goals, new_vm, new_counter} <-
           rewrite_predicate(inner, params, vm, counter) do
      {:ok, {:not, new_inner}, goals, new_vm, new_counter}
    end
  end

  defp rewrite_predicate({:cmp, op, {:call, name, args}, rhs}, params, vm, counter)
       when name not in @known_call_names do
    rewrite_call_comparison(op, name, args, rhs, params, vm, counter)
  end

  defp rewrite_predicate(predicate, _params, vm, counter), do: {:ok, predicate, [], vm, counter}

  defp rewrite_combinator(tag, left, right, params, vm, counter) do
    with {:ok, new_left, left_goals, vm2, counter2} <-
           rewrite_predicate(left, params, vm, counter),
         {:ok, new_right, right_goals, vm3, counter3} <-
           rewrite_predicate(right, params, vm2, counter2) do
      {:ok, {tag, new_left, new_right}, left_goals ++ right_goals, vm3, counter3}
    end
  end

  defp rewrite_call_comparison(op, name, args, rhs, params, vm, counter) do
    with {:ok, call_terms, vm2} <- resolve_args(args, params, vm),
         fresh_name = "$goal_out_#{counter + 1}",
         fresh_var = Term.new_var(fresh_name),
         {:ok, goal} <- goal_for_functor(name, call_terms ++ [fresh_var]) do
      new_cmp = {:cmp, op, [fresh_name], rhs}
      {:ok, new_cmp, [goal], vm2, counter + 1}
    end
  end

  # ---- row conversion ---------------------------------------------------

  # `Episteme.query/2` already returns each solution as a `%{name =>
  # value}` map, keyed by exactly the variable names this module built
  # (source args, plus every `$goal_out_N` fresh output var) -- no
  # separate binding-to-row extraction step is needed the way `Scry.
  # Logic.Executor.bindings_to_row/2` requires; only the *values*
  # themselves need normalizing to something `Scry.Core.QueryOps` can
  # compare against a row.
  defp normalize_row(solution),
    do: Map.new(solution, fn {name, value} -> {name, normalize_value(value)} end)

  # An unresolved variable in a solution means the query never
  # constrained it to any value -- represented as `nil`, the same
  # "genuinely absent" value an unmatched field already gets elsewhere
  # in this ecosystem, not an error.
  defp normalize_value(%Var{}), do: nil

  defp normalize_value(value)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value) do
    value
  end

  defp normalize_value(%Scry.Core.Rational{} = value), do: value

  # A compound or list binding -- see this module's own moduledoc,
  # "Stated scope limits" section, for why this renders to text rather
  # than surfacing as a nested structure.
  defp normalize_value(other), do: Term.to_text(other)
end
