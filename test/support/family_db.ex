defmodule Scry.Engine.Episteme.Test.FamilyDB do
  @moduledoc """
  The same family-tree domain `scry_test_logic`'s own `Scry.Test.Logic.Seed`
  uses (`parent`/`age`/`ancestor`, tom -> bob -> {ann, pat}) -- but built
  the ordinary Episteme way, via `Episteme.Database.add_fact/2`/
  `add_clause/2` against real `Episteme.Term.Compound{}` terms, not
  hand-written `[term()] -> Ichor.Backtrack.goal()` closures. `ancestor/2`
  is written as an ordinary recursive rule, with no extra laziness
  wrapper -- see `Scry.Engine.Episteme`'s own moduledoc for why none is
  needed here, unlike `scry_logic`'s own reference `conn`.
  """

  alias Episteme.Database
  alias Episteme.Term
  alias Episteme.Term.Compound

  @spec build() :: Database.t()
  def build do
    Database.new()
    |> add_facts(:parent, [{"tom", "bob"}, {"bob", "ann"}, {"bob", "pat"}])
    |> add_facts(:age, [{"tom", 60}, {"bob", 35}, {"ann", 10}, {"pat", 8}])
    |> add_ancestor_rules()
  end

  defp add_facts(db, name, pairs) do
    Enum.reduce(pairs, db, fn {a, b}, db ->
      Database.add_fact(db, %Compound{name: name, args: [a, b]})
    end)
  end

  # ancestor(X, Y) :- parent(X, Y).
  # ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
  defp add_ancestor_rules(db) do
    {x1, y1} = {Term.new_var("X"), Term.new_var("Y")}
    {x2, y2, z2} = {Term.new_var("X"), Term.new_var("Y"), Term.new_var("Z")}

    db
    |> Database.add_clause(
      {%Compound{name: :ancestor, args: [x1, y1]}, %Compound{name: :parent, args: [x1, y1]}}
    )
    |> Database.add_clause(
      {%Compound{name: :ancestor, args: [x2, y2]},
       %Compound{
         name: :and,
         args: [
           %Compound{name: :parent, args: [x2, z2]},
           %Compound{name: :ancestor, args: [z2, y2]}
         ]
       }}
    )
  end
end
