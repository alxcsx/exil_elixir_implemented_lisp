defmodule Backend.InterpreterTest do
  use ExUnit.Case, async: true
  alias Backend.Interpreter
  alias Core.AST
  alias Core.AST.{Identifier, List, Literal, Tuple}
  alias Core.Env
  alias Midfield.MacroExpander

  def id(name), do: %Identifier{name: name}
  def int(val), do: %Literal{type: :Int, value: val}
  def str(val), do: %Literal{type: :Str, value: val}
  def key(val), do: %Literal{type: :Key, value: val}
  def lst(elems), do: %List{elements: elems}
  def tup(elems), do: %Tuple{elements: elems}

  describe "Basic evaluation" do
    test "evaluates literals and keywords" do
      env = Interpreter.new_context()
      assert {42, _} = Interpreter.eval(int(42), env)
      assert {"hi", _} = Interpreter.eval(str("hi"), env)
      assert {true, _} = Interpreter.eval(key(true), env)
      assert {false, _} = Interpreter.eval(key(false), env)
      assert {nil, _} = Interpreter.eval(key(nil), env)
    end

    test "evaluates arithmetic built-ins" do
      env = Interpreter.new_context()
      # (+ 1 2 3)
      assert {6, _} = Interpreter.eval(lst([id(:+), int(1), int(2), int(3)]), env)
      # (- 10 3 2)
      assert {5, _} = Interpreter.eval(lst([id(:-), int(10), int(3), int(2)]), env)
      # (* 4 5)
      assert {20, _} = Interpreter.eval(lst([id(:*), int(4), int(5)]), env)
      # (/ 10 2)
      assert {5, _} = Interpreter.eval(lst([id(:/), int(10), int(2)]), env)
      # (** 2 3)
      assert {8, _} = Interpreter.eval(lst([id(:**), int(2), int(3)]), env)
    end

    test "evaluates comparisons and not" do
      env = Interpreter.new_context()
      assert {true, _} = Interpreter.eval(lst([id(:==), int(5), int(5)]), env)
      assert {false, _} = Interpreter.eval(lst([id(:==), int(5), int(6)]), env)
      assert {true, _} = Interpreter.eval(lst([id(:<), int(3), int(5)]), env)
      assert {true, _} = Interpreter.eval(lst([id(:not), key(false)]), env)
      assert {false, _} = Interpreter.eval(lst([id(:not), key(true)]), env)
    end
  end

  describe "Special forms" do
    test "def binds module variable and allows retrieval" do
      env = %{Env.new() | current_module: :main}
      def_form = lst([id(:def), id(:a), int(100)])

      assert {100, new_env} = Interpreter.eval(def_form, env)
      assert {100, _} = Interpreter.eval(id(:a), new_env)
    end

    test "let binds local variables with sequential dependency" do
      env = Env.new()
      # (let [x 10 y (+ x 5)] (+ x y))
      let_form =
        lst([
          id(:let),
          tup([id(:x), int(10), id(:y), lst([id(:+), id(:x), int(5)])]),
          lst([id(:+), id(:x), id(:y)])
        ])

      assert {25, _} = Interpreter.eval(let_form, env)
    end

    test "if evaluates conditionally" do
      env = Interpreter.new_context()
      true_form = lst([id(:if), key(true), int(1), int(2)])
      false_form = lst([id(:if), key(false), int(1), int(2)])

      assert {1, _} = Interpreter.eval(true_form, env)
      assert {2, _} = Interpreter.eval(false_form, env)
    end

    test "fn closures execute with lexical scoping" do
      env = Env.new()
      # ((fn [x] (+ x 10)) 5)
      fn_call = lst([lst([id(:fn), tup([id(:x)]), lst([id(:+), id(:x), int(10)])]), int(5)])

      assert {15, _} = Interpreter.eval(fn_call, env)
    end

    test "recursive functions work via def" do
      env = %{Env.new() | current_module: :main}

      # (def fact (fn [n] (if (== n 0) 1 (* n (fact (- n 1))))))
      def_fact =
        lst([
          id(:def),
          id(:fact),
          lst([
            id(:fn),
            tup([id(:n)]),
            lst([
              id(:if),
              lst([id(:==), id(:n), int(0)]),
              int(1),
              lst([id(:*), id(:n), lst([id(:fact), lst([id(:-), id(:n), int(1)])])])
            ])
          ])
        ])

      {_closure, env} = Interpreter.eval(def_fact, env)

      # (fact 5) => 120
      call = lst([id(:fact), int(5)])
      assert {120, _} = Interpreter.eval(call, env)
    end

    test "_ffi calls Erlang and Elixir functions" do
      env = Env.new()
      # ((_ffi :erlang :+ 2) 3 7)
      ffi_call =
        lst([
          lst([
            id(:_ffi),
            %Literal{type: :Key, value: :erlang},
            %Literal{type: :Key, value: :+},
            int(2)
          ]),
          int(3),
          int(7)
        ])

      assert {10, _} = Interpreter.eval(ffi_call, env)
    end
  end

  describe "Quasiquote and macro evaluator integration" do
    test "quasiquote expands unquote and unquote-splicing with injected macro context" do
      env =
        Env.new()
        |> Env.put_var(:x, int(42))
        |> Env.put_var(:items, tup([int(1), int(2)]))
        |> MacroExpander.inject_macro_context()

      # (quote (+ (unquote x) (unquote-splicing items)))
      qq_form =
        lst([
          id(:quote),
          lst([
            id(:+),
            lst([id(:unquote), id(:x)]),
            lst([id(:"unquote-splicing"), id(:items)])
          ])
        ])

      assert {%AST.List{
                elements: [
                  %AST.Identifier{name: :+},
                  %AST.Literal{value: 42},
                  %AST.Literal{value: 1},
                  %AST.Literal{value: 2}
                ]
              }, _} =
               Interpreter.eval(qq_form, env)
    end

    test "quote is not available in normal runtime interpreter context" do
      env = Interpreter.new_context()
      qq_form = lst([id(:quote), int(42)])

      assert_raise RuntimeError, ~r/variável não definida: quote/, fn ->
        Interpreter.eval(qq_form, env)
      end
    end

    test "macros can use compile-time if conditionals and computation" do
      env = Env.new()

      # (defmacro choose [flag val]
      #   (if flag
      #     (quote (+ (unquote val) 10))
      #     (quote (+ (unquote val) 20))))
      macro =
        lst([
          id(:defmacro),
          id(:choose),
          tup([id(:flag), id(:val)]),
          lst([
            id(:if),
            id(:flag),
            lst([id(:quote), lst([id(:+), lst([id(:unquote), id(:val)]), int(10)])]),
            lst([id(:quote), lst([id(:+), lst([id(:unquote), id(:val)]), int(20)])])
          ])
        ])

      {nil, env} = MacroExpander.expand(macro, env)

      # (choose :true 5) expands to (+ 5 10)
      assert {%AST.List{elements: [_, %AST.Literal{value: 5}, %AST.Literal{value: 10}]}, _} =
               MacroExpander.expand(lst([id(:choose), key(true), int(5)]), env)

      # (choose :false 5) expands to (+ 5 20)
      assert {%AST.List{elements: [_, %AST.Literal{value: 5}, %AST.Literal{value: 20}]}, _} =
               MacroExpander.expand(lst([id(:choose), key(false), int(5)]), env)
    end

    test "macros can compute values at expansion time" do
      env = Env.new()

      # (defmacro compile-sum [a b]
      #   (+ a b))
      macro =
        lst([
          id(:defmacro),
          id(:compile_sum),
          tup([id(:a), id(:b)]),
          lst([id(:+), id(:a), id(:b)])
        ])

      {nil, env} = MacroExpander.expand(macro, env)

      # (compile-sum 3 4) expands to literal 7
      assert {%AST.Literal{type: :Int, value: 7}, _} =
               MacroExpander.expand(lst([id(:compile_sum), int(3), int(4)]), env)
    end
  end

  describe "Pipeline integration" do
    test "evaluates whole programs through Pipeline.run" do
      assert {:ok, [15], _env} = Pipeline.run("(+ 5 10)")
      assert {:ok, [30], _env} = Pipeline.run("(def a 10) (def b 20) (+ a b)")
    end

    test "evaluates subtyping check with <:" do
      code = """
      (<: 
        {:x {:a Int :b Int} :y {:m Int}}
        {:x {:a Int} :y {}}
      )
      """

      assert {:ok, [true], _env} = Pipeline.run(code)

      false_code = """
      (<: 
        {:x {:a Int} :y {}}
        {:x {:a Int :b Int} :y {:m Int}}
      )
      """

      assert {:ok, [false], _env} = Pipeline.run(false_code)
    end

    test "functions and macros work together in Pipeline.run" do
      code = """
      (defmacro add-five [x]
        (quote (+ (unquote x) 5)))

      (def inc (fn [x] (add-five x)))
      (inc 10)
      """

      assert {:ok, [15], _env} = Pipeline.run(code)
    end

    test "subtyping with prelude Bool and union (u :true :false)" do
      assert {:ok, [true], _} = Pipeline.run("(<: :true Bool)")
      assert {:ok, [true], _} = Pipeline.run("(<: :false Bool)")
      assert {:ok, [false], _} = Pipeline.run("(<: :nil Bool)")
      assert {:ok, [true], _} = Pipeline.run("(<: (u :true :false) Bool)")
      assert {:ok, [true], _} = Pipeline.run("(<: Bool (u :true :false))")
      assert {:ok, [true], _} = Pipeline.run("(<: Bool (U :true :false))")
    end

    test "custom macro handlers can be injected into RuntimeEnv" do
      runtime_env =
        Core.RuntimeEnv.new()
        |> Core.RuntimeEnv.put_macro_handler(:custom_double, fn [arg], env ->
          {val, env1} = Backend.Interpreter.eval(arg, env)
          {val * 2, env1}
        end)

      form = lst([id(:custom_double), int(21)])
      assert {42, _} = Backend.Interpreter.eval(form, runtime_env)
    end
  end
end
