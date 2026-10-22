defmodule Midfield.MacroExpanderTests do
  use ExUnit.Case
  alias Midfield.MacroExpander

  alias Core.AST
  alias Core.Env

  # --- Helpers ---
  def id(name), do: %AST.Identifier{name: name}
  def int(val), do: %AST.Literal{type: :Int, value: val}
  def lst(elems), do: %AST.List{elements: elems}
  def tup(elems), do: %AST.Tuple{elements: elems}
  def map_node(pairs), do: %AST.Map{pairs: pairs}

  describe "AST Expansion" do
    test "keeps non-macro calls as raw lists" do
      env = Env.new()
      # (+ 1 2)
      ast = lst([id(:+), int(1), int(2)])

      assert {%AST.List{
                elements: [
                  %AST.Identifier{name: :+},
                  %AST.Literal{type: :Int, value: 1},
                  %AST.Literal{type: :Int, value: 2}
                ]
              }, _new_env} =
               MacroExpander.expand(ast, env)
    end

    test "defmacro stores definition in Env" do
      env = Env.new(macro_engine: :interpreter)

      # (defmacro identity [x] x)
      macro_ast =
        lst([
          id(:defmacro),
          id(:identity),
          tup([id(:x)]),
          id(:x)
        ])

      assert {nil, new_env} = MacroExpander.expand(macro_ast, env)
      assert Env.has_macro?(new_env, :identity)

      macro_def = Env.get_macro(new_env, :identity)
      assert macro_def.name == :identity
      assert macro_def.args == [id(:x)]

      # Pruning check
      assert {[], _env} = MacroExpander.expand_list([macro_ast], env)
    end

    test "defmacro is removed from the AST after evaluated" do
      env = Env.new(macro_engine: :interpreter)

      # (defmacro identity (x) x)
      macro_ast =
        lst([
          id(:defmacro),
          id(:identity),
          tup([id(:x)]),
          lst([id(:x)])
        ])

      assert {[], _env} = MacroExpander.expand_list([macro_ast], env)
    end

    test "quote wraps its body without expanding inner nodes" do
      env = Env.new()
      # (quote (+ 1 2))
      ast = lst([id(:quote), lst([id(:+), int(1), int(2)])])

      assert {^ast, _env} = MacroExpander.expand(ast, env)
    end

    test "template macros splice their raw AST arguments" do
      env = Env.new()

      macro =
        lst([
          id(:defmacro),
          id(:unless),
          tup([id(:condition), id(:body)]),
          lst([
            id(:quote),
            lst([
              id(:if),
              lst([id(:unquote), id(:condition)]),
              lst([id(:quote), id(nil)]),
              lst([id(:unquote), id(:body)])
            ])
          ])
        ])

      {nil, env} = MacroExpander.expand(macro, env)

      assert {%AST.List{elements: [if_node, condition, _nil, body]}, _env} =
               MacroExpander.expand(lst([id(:unless), id(:ready), lst([id(:work)])]), env)

      assert if_node == id(:if)
      assert condition == id(:ready)
      assert body == lst([id(:work)])
    end

    test "an unquote outside a macro template is invalid" do
      assert_raise RuntimeError, ~r/unquote só pode/, fn ->
        MacroExpander.expand(lst([id(:unquote), id(:value)]), Env.new())
      end
    end

    test "template macros splice tuple elements into a quoted list" do
      macro =
        lst([
          id(:defmacro),
          id(:begin),
          tup([id(:forms)]),
          lst([
            id(:quote),
            lst([
              id(:let),
              tup([]),
              lst([id(:"unquote-splicing"), id(:forms)])
            ])
          ])
        ])

      {nil, env} = MacroExpander.expand(macro, Env.new())

      assert {%AST.List{elements: [let, %AST.Tuple{elements: []}, first, second]}, _env} =
               MacroExpander.expand(
                 lst([id(:begin), tup([lst([id(:first)]), lst([id(:second)])])]),
                 env
               )

      assert let == id(:let)
      assert first == lst([id(:first)])
      assert second == lst([id(:second)])
    end

    test "macro rest parameters bind the remaining raw AST arguments" do
      macro =
        lst([
          id(:defmacro),
          id(:begin),
          tup([id(:first), id(:|), id(:rest)]),
          lst([
            id(:quote),
            lst([
              id(:let),
              tup([]),
              lst([id(:unquote), id(:first)]),
              lst([id(:"unquote-splicing"), id(:rest)])
            ])
          ])
        ])

      {nil, env} = MacroExpander.expand(macro, Env.new())

      assert {%AST.List{elements: [_, _, first, second, third]}, _env} =
               MacroExpander.expand(
                 lst([id(:begin), lst([id(:first)]), lst([id(:second)]), lst([id(:third)])]),
                 env
               )

      assert first == lst([id(:first)])
      assert second == lst([id(:second)])
      assert third == lst([id(:third)])
    end

    test "unquote-splicing outside a macro template is invalid" do
      assert_raise RuntimeError, ~r/unquote-splicing só pode/, fn ->
        MacroExpander.expand(lst([id(:"unquote-splicing"), id(:forms)]), Env.new())
      end
    end

    test "import is pruned and registered in Env" do
      env = Env.new(macro_engine: :interpreter)

      assert {nil, env} = MacroExpander.expand(lst([id(:import), id(:foo)]), env)
      assert env.imports == [:foo]

      assert {nil, env} =
               MacroExpander.expand(lst([id(:import), id(:bar), id(:as), id(:b)]), env)

      assert env.aliases[:b] == :bar
      assert env.imports == [:foo]
    end
  end

  describe "Macro invocation" do
    test "a macro body can return one of its arguments directly" do
      env = Env.new(macro_engine: :interpreter)

      # (defmacro identity (x) x)
      macro_def = %{name: :identity, args: [id(:x)], rest: nil, body: [id(:x)]}

      env = Env.put_macro(env, :identity, macro_def)

      # (identity 42)
      call_ast = lst([id(:identity), int(42)])
      assert {%AST.Literal{type: :Int, value: 42}, _new_env} = MacroExpander.expand(call_ast, env)
    end

    test "expands macro calls inside tuples and maps" do
      env = Env.new()

      macro =
        lst([
          id(:defmacro),
          id(:inc),
          tup([id(:x)]),
          lst([id(:quote), lst([id(:+), lst([id(:unquote), id(:x)]), int(1)])])
        ])

      {nil, env} = MacroExpander.expand(macro, env)

      # [ (inc 1) 2 ]
      tuple_ast = tup([lst([id(:inc), int(1)]), int(2)])

      assert {%AST.Tuple{elements: [expanded_inc, %AST.Literal{value: 2}]}, _env} =
               MacroExpander.expand(tuple_ast, env)

      assert expanded_inc == lst([id(:+), int(1), int(1)])

      # {:k (inc 5)}
      map_ast = map_node([{id(:k), lst([id(:inc), int(5)])}])

      assert {%AST.Map{pairs: [{%AST.Identifier{name: :k}, expanded_val}]}, _env} =
               MacroExpander.expand(map_ast, env)

      assert expanded_val == lst([id(:+), int(5), int(1)])
    end

    test "prevents infinite macro expansion with recursion limit" do
      env = Env.new()

      loop_macro =
        lst([
          id(:defmacro),
          id(:loop_forever),
          tup([]),
          lst([id(:quote), lst([id(:loop_forever)])])
        ])

      {nil, env} = MacroExpander.expand(loop_macro, env)

      assert_raise RuntimeError, ~r/limite de expansão de macro excedido/, fn ->
        MacroExpander.expand(lst([id(:loop_forever)]), env)
      end
    end

    test "rejects malformed defmacro forms" do
      env = Env.new()

      assert_raise RuntimeError, ~r/sintaxe inválida para defmacro/, fn ->
        MacroExpander.expand(lst([id(:defmacro)]), env)
      end

      assert_raise RuntimeError, ~r/sintaxe inválida para defmacro/, fn ->
        MacroExpander.expand(lst([id(:defmacro), int(123), tup([id(:x)]), id(:x)]), env)
      end
    end

    test "rejects unquote with invalid arity in macro template" do
      env = Env.new()

      bad_unquote_macro =
        lst([
          id(:defmacro),
          id(:bad),
          tup([]),
          lst([id(:quote), lst([id(:foo), lst([id(:unquote)])])])
        ])

      {nil, env} = MacroExpander.expand(bad_unquote_macro, env)

      assert_raise RuntimeError, ~r/unquote deve receber exatamente um parâmetro/, fn ->
        MacroExpander.expand(lst([id(:bad)]), env)
      end
    end

    test "macroexpand_1 expands only top level once" do
      env = Env.new()

      inner_macro =
        lst([
          id(:defmacro),
          id(:inner),
          tup([id(:x)]),
          lst([id(:quote), lst([id(:+), lst([id(:unquote), id(:x)]), int(1)])])
        ])

      outer_macro =
        lst([
          id(:defmacro),
          id(:outer),
          tup([id(:x)]),
          lst([id(:quote), lst([id(:inner), lst([id(:unquote), id(:x)])])])
        ])

      {nil, env} = MacroExpander.expand(inner_macro, env)
      {nil, env} = MacroExpander.expand(outer_macro, env)

      call = lst([id(:outer), int(10)])

      # macroexpand_1 produces (inner 10)
      assert %AST.List{elements: [%AST.Identifier{name: :inner}, %AST.Literal{value: 10}]} =
               MacroExpander.macroexpand_1(call, env)

      # macroexpand produces (+ 10 1)
      assert %AST.List{
               elements: [
                 %AST.Identifier{name: :+},
                 %AST.Literal{value: 10},
                 %AST.Literal{value: 1}
               ]
             } = MacroExpander.macroexpand(call, env)
    end

    test "MacroExpander.run returns {:error, reason} on failure" do
      env = Env.new()
      bad_module = %AST.Module{name: :main, body: [lst([id(:unquote), id(:x)])]}

      assert {:error, msg} = MacroExpander.run(bad_module, env)
      assert msg =~ "unquote só pode"
    end
  end
end
