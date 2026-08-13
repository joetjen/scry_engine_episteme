defmodule Scry.Engine.EpistemeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Episteme.Database
  alias Episteme.Term.Compound
  alias Scry.Core.CombinedQuery
  alias Scry.Engine.Episteme, as: Engine
  alias Scry.Engine.Episteme.Test.FamilyDB

  defp run!(query_text, params \\ %{}) do
    {:ok, query} = Scry.Core.parse(query_text)
    {:ok, rows} = Engine.execute(FamilyDB.build(), query, params)
    Enum.to_list(rows)
  end

  describe "a call-shaped source, resolved against a real Episteme.Database" do
    test "an unbound goal returns every fact, in clause order" do
      assert run!("SELECT parent(X, Y) { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"},
               %{"X" => "bob", "Y" => "ann"},
               %{"X" => "bob", "Y" => "pat"}
             ]
    end

    test "a ground first argument narrows the search" do
      assert run!("SELECT parent(\"bob\", Y) { Y }") == [%{"Y" => "ann"}, %{"Y" => "pat"}]
    end

    test "a fully ground goal succeeds with an empty (still one-row) binding" do
      assert run!("SELECT parent(\"tom\", \"bob\") { ok: \"matched\" }") == [
               %{"ok" => "matched"}
             ]
    end

    test "a fully ground goal that doesn't hold produces zero rows" do
      assert run!("SELECT parent(\"ann\", \"bob\") { ok: \"matched\" }") == []
    end
  end

  describe "a real behavioral divergence from scry_logic's own reference engine" do
    test "a genuinely undefined relation is a query_error, not a silent empty result" do
      {:ok, query} = Scry.Core.parse("SELECT nope(X) { X }")

      assert {:error, {:query_error, {:existence_error, :procedure, {"nope", 1}}}} =
               Engine.execute(FamilyDB.build(), query, %{})
    end

    test "a defined relation with no matching clause still simply fails (zero solutions)" do
      assert run!("SELECT parent(\"ann\", \"bob\") { ok: \"matched\" }") == []
    end

    test "a relation declared dynamic with zero facts is defined-but-empty, not undefined" do
      db = Database.declare_dynamic(Database.new(), :empty_rel, 1)
      {:ok, query} = Scry.Core.parse("SELECT empty_rel(X) { X }")
      assert {:ok, rows} = Engine.execute(db, query, %{})
      assert Enum.to_list(rows) == []
    end
  end

  describe "the lang_spec.md §8.4 worked example -- a WHERE-embedded goal call" do
    test "age(Y) > 10 conjoins a second goal and filters by its own resolved value" do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 10 { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"}
             ]
    end

    test "combined with an ordinary AND against a ground value" do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 10 AND Y = \"bob\" { X, Y }") == [
               %{"X" => "tom", "Y" => "bob"}
             ]
    end

    test "no facts satisfy the embedded goal's own comparison" do
      assert run!("SELECT parent(X, Y) WHERE age(Y) > 1000 { X, Y }") == []
    end
  end

  describe "recursion -- an ordinary Episteme rule, no laziness wrapper needed" do
    test "ancestor/2 terminates and returns every solution" do
      assert run!("SELECT ancestor(\"tom\", Y) { Y }") == [
               %{"Y" => "bob"},
               %{"Y" => "ann"},
               %{"Y" => "pat"}
             ]
    end

    test "a leaf with no descendants has zero ancestor solutions" do
      assert run!("SELECT ancestor(\"pat\", Y) { Y }") == []
    end
  end

  describe "delegation to Scry.Core.QueryOps.run_flat/3 for everything else" do
    test "ORDER BY and LIMIT apply to the resolved rows" do
      assert run!("SELECT parent(X, Y) ORDER BY Y DESC LIMIT 1 { Y }") == [%{"Y" => "pat"}]
    end

    test "projection only returns the requested fields" do
      assert run!("SELECT parent(X, Y) { X }") == [
               %{"X" => "tom"},
               %{"X" => "bob"},
               %{"X" => "bob"}
             ]
    end

    test "a synthesized fresh-variable field never leaks into the projected row" do
      [row | _] = run!("SELECT parent(X, Y) WHERE age(Y) > 10 { X, Y }")
      refute Map.has_key?(row, "$goal_out_1")
    end
  end

  describe "external $params" do
    test "a $param goal argument resolves against the params map" do
      assert run!("SELECT parent(\"bob\", $child) { ok: \"matched\" }", %{"child" => "ann"}) ==
               [%{"ok" => "matched"}]
    end

    test "a missing $param is a clear query error, not a crash" do
      {:ok, query} = Scry.Core.parse("SELECT parent(\"bob\", $child) { ok: \"matched\" }")

      assert {:error, {:query_error, {:missing_param, "child"}}} =
               Engine.execute(FamilyDB.build(), query, %{})
    end
  end

  describe "stated scope limits" do
    test "goal_args: nil (an ordinary, non-goal query) is declined" do
      {:ok, query} = Scry.Core.parse("SELECT users { name }")

      assert {:error, {:unsupported, {:construct, :non_goal_source}}} =
               Engine.execute(FamilyDB.build(), query, %{})
    end

    test "a CombinedQuery (UNION/INTERSECT/EXCEPT) is declined" do
      {:ok, %CombinedQuery{} = combined} =
        Scry.Core.parse("SELECT parent(X, Y) { Y } UNION SELECT parent(X, Y) { Y }")

      assert {:error, {:unsupported, {:construct, :combined_query}}} =
               Engine.execute(FamilyDB.build(), combined, %{})
    end

    test "an unsupported goal-argument shape (an arithmetic expression) is declined clearly" do
      {:ok, query} = Scry.Core.parse("SELECT parent(1 + 1, Y) { Y }")

      assert {:error, {:unsupported, {:goal_argument, _}}} =
               Engine.execute(FamilyDB.build(), query, %{})
    end

    test "a compound-valued binding renders to text rather than leaking a raw Episteme term" do
      db =
        Database.new()
        |> Database.add_fact(%Compound{
          name: :holds,
          args: [%Compound{name: :pair, args: [1, 2]}]
        })

      {:ok, query} = Scry.Core.parse("SELECT holds(X) { X }")
      {:ok, rows} = Engine.execute(db, query, %{})
      assert Enum.to_list(rows) == [%{"X" => "pair(1, 2)"}]
    end
  end

  describe "run/3 wraps the result in a Scry.Core.Cursor" do
    test "run/3 returns a real, iterable cursor" do
      {:ok, query} = Scry.Core.parse("SELECT parent(X, Y) { X, Y }")
      assert {:ok, cursor} = Engine.run(query, FamilyDB.build())
      assert Scry.Core.Cursor.to_list(cursor) == run!("SELECT parent(X, Y) { X, Y }")
    end
  end

  describe "property: an arbitrary ground-fact relation" do
    property "SELECT rel(X, Y) { X, Y } always returns exactly the declared facts, in order" do
      check all(
              facts <-
                list_of(
                  {string(:alphanumeric, min_length: 1, max_length: 6),
                   string(:alphanumeric, min_length: 1, max_length: 6)},
                  max_length: 12
                )
            ) do
        db =
          Enum.reduce(facts, Database.declare_dynamic(Database.new(), :rel, 2), fn {x, y}, db ->
            Database.add_fact(db, %Compound{name: :rel, args: [x, y]})
          end)

        {:ok, query} = Scry.Core.parse("SELECT rel(X, Y) { X, Y }")
        {:ok, rows} = Engine.execute(db, query, %{})

        expected = Enum.map(facts, fn {x, y} -> %{"X" => x, "Y" => y} end)
        assert Enum.to_list(rows) == expected
      end
    end

    property "a repeated variable name only matches pairs whose two arguments are equal" do
      check all(
              pairs <-
                list_of(
                  {string(:alphanumeric, min_length: 1, max_length: 4),
                   string(:alphanumeric, min_length: 1, max_length: 4)},
                  max_length: 12
                )
            ) do
        db =
          Enum.reduce(pairs, Database.declare_dynamic(Database.new(), :pair, 2), fn {a, b}, db ->
            Database.add_fact(db, %Compound{name: :pair, args: [a, b]})
          end)

        {:ok, query} = Scry.Core.parse("SELECT pair(X, X) { X }")
        {:ok, rows} = Engine.execute(db, query, %{})

        expected = for {a, b} <- pairs, a == b, do: %{"X" => a}
        assert Enum.to_list(rows) == expected
      end
    end
  end
end
