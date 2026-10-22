defmodule Stdlib.AstTest do
  use ExUnit.Case, async: true

  describe "Ast module import and construction" do
    test "imports Ast and constructs nodes" do
      code = """
      (import Ast as ast)
      (def node (ast/id :my_var))
      (def int-node (ast/int 100))
      [(ast/id? node) (ast/name node) (ast/literal? int-node) (ast/value int-node) (ast/type int-node)]
      """

      assert {:ok, results, _env} = Pipeline.run(code)
      assert {true, :my_var, true, 100, :Int} = List.last(results)
    end

    test "constructs call nodes and evaluates macros built with Ast" do
      code = """
      (import Ast as ast)

      (defmacro make-sum [a b]
        (ast/call (ast/id :+) a b))

      (def compute (fn [x] (make-sum x (ast/int 40))))
      (compute 2)
      """

      assert {:ok, results, _env} = Pipeline.run(code)
      assert 42 = List.last(results)
    end

    test "works with list argument calling convention in ast/call" do
      code = """
      (import Ast as ast)

      (defmacro make-sum-list [a b]
        (ast/call (ast/id :+) [a b]))

      (def compute (fn [x] (make-sum-list x (ast/int 10))))
      (compute 5)
      """

      assert {:ok, results, _env} = Pipeline.run(code)
      assert 15 = List.last(results)
    end

    test "constructs tuples and maps" do
      code = """
      (import Ast as ast)
      (def t (ast/tuple [(ast/int 1) (ast/int 2)]))
      (def m (ast/map {:a (ast/int 10)}))
      [(ast/tuple? t) (ast/map? m)]
      """

      assert {:ok, results, _env} = Pipeline.run(code)
      assert {true, true} = List.last(results)
    end

    test "type checker enforces specs on Ast functions" do
      bad_arg = """
      (import Ast as ast)
      (ast/int "not an int")
      """

      assert {:error, msg} = Pipeline.run(bad_arg)
      assert msg =~ "argumento de ast/int tem tipo :Str, esperado :Int"

      bad_type = """
      (import Ast as ast)
      (ast/literal 10 :Unknown)
      """

      assert {:error, msg} = Pipeline.run(bad_type)
      assert msg =~ "argumento de ast/literal tem tipo {:Symbol, :Unknown}"
    end
  end
end
