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
      # (+ 1 2)
      assert {3, _} = Interpreter.eval(lst([id(:+), int(1), int(2)]), env)
      # (- 10 3)
      assert {7, _} = Interpreter.eval(lst([id(:-), int(10), int(3)]), env)
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
      env = Interpreter.new_context()
      # (let [x 10 y (+ x 5)] (+ x y))
      let_form =
        lst([
          id(:let),
          tup([id(:x), int(10), id(:y), lst([id(:+), id(:x), int(5)])]),
          lst([id(:+), id(:x), id(:y)])
        ])

      assert {25, _} = Interpreter.eval(let_form, env)
    end

    test "if evaluates conditionally and lazily" do
      env = Interpreter.new_context()
      true_form = lst([id(:if), key(true), int(1), int(2)])
      false_form = lst([id(:if), key(false), int(1), int(2)])

      assert {1, _} = Interpreter.eval(true_form, env)
      assert {2, _} = Interpreter.eval(false_form, env)

      # Truthiness semantics: nil is falsy, truthy collections/zero
      assert {2, _} = Interpreter.eval(lst([id(:if), key(nil), int(1), int(2)]), env)
      assert {1, _} = Interpreter.eval(lst([id(:if), int(0), int(1), int(2)]), env)
      assert {1, _} = Interpreter.eval(lst([id(:if), str(""), int(1), int(2)]), env)
      assert {1, _} = Interpreter.eval(lst([id(:if), tup([]), int(1), int(2)]), env)

      # Lazy evaluation: dead branch is not evaluated (division by zero would raise)
      div_zero = lst([id(:/), int(10), int(0)])
      assert {1, _} = Interpreter.eval(lst([id(:if), key(true), int(1), div_zero]), env)
      assert {2, _} = Interpreter.eval(lst([id(:if), key(false), div_zero, int(2)]), env)
    end

    test "let evaluates bindings sequentially and supports multiple body expressions" do
      env = Interpreter.new_context()

      # (let [x 10 y (+ x 5)] (def a 1) (+ x y)) -> returns (+ x y)
      multi_body_let =
        lst([
          id(:let),
          tup([id(:x), int(10), id(:y), lst([id(:+), id(:x), int(5)])]),
          int(999),
          lst([id(:+), id(:x), id(:y)])
        ])

      assert {25, _} = Interpreter.eval(multi_body_let, env)
    end

    test "closures have lexical scope even when shadowed externally" do
      env = Interpreter.new_context()

      # (let [x 10] (let [f (fn [] x) x 20] (f)))
      expr =
        lst([
          id(:let),
          tup([id(:x), int(10)]),
          lst([
            id(:let),
            tup([
              id(:f),
              lst([id(:fn), tup([]), id(:x)]),
              id(:x),
              int(20)
            ]),
            lst([id(:f)])
          ])
        ])

      assert {10, _} = Interpreter.eval(expr, env)
    end

    test "recursive function parameter shadows function name" do
      env = %{Interpreter.new_context() | current_module: :main}

      # (def f (fn [f] f))
      # (f 42) -> should return 42 without recursion loop
      def_f =
        lst([
          id(:def),
          id(:f),
          lst([id(:fn), tup([id(:f)]), id(:f)])
        ])

      {_closure, env} = Interpreter.eval(def_f, env)
      assert {42, _} = Interpreter.eval(lst([id(:f), int(42)]), env)
    end

    test "arithmetic runtime edge cases" do
      env = Interpreter.new_context()

      # Division by zero raises ArithmeticError
      assert_raise ArithmeticError, fn ->
        Interpreter.eval(lst([id(:/), int(10), int(0)]), env)
      end

      # Power 0
      assert {1, _} = Interpreter.eval(lst([id(:**), int(5), int(0)]), env)

      # Mixed arithmetic int + float via erlang +
      assert {3.5, _} =
               Interpreter.eval(
                 lst([id(:+), int(1), %Literal{type: :Float, value: 2.5}]),
                 env
               )
    end

    test "fn closures execute with lexical scoping" do
      env = Interpreter.new_context()
      # ((fn [x] (+ x 10)) 5)
      fn_call = lst([lst([id(:fn), tup([id(:x)]), lst([id(:+), id(:x), int(10)])]), int(5)])

      assert {15, _} = Interpreter.eval(fn_call, env)
    end

    test "recursive functions work via def" do
      env = %{Interpreter.new_context() | current_module: :main}

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
    test "quasiquote expands unquote and unquote-splicing in MacroExpander" do
      env = Env.new()

      # (def-macro qq [x items] (quote (+ (unquote x) (unquote-splicing items))))
      macro =
        lst([
          id(:"def-macro"),
          id(:qq),
          tup([id(:x), id(:items)]),
          lst([
            id(:quote),
            lst([
              id(:+),
              lst([id(:unquote), id(:x)]),
              lst([id(:"unquote-splicing"), id(:items)])
            ])
          ])
        ])

      {nil, env} = MacroExpander.expand(macro, env)

      assert {%AST.List{
                elements: [
                  %AST.Identifier{name: :+},
                  %AST.Literal{value: 42},
                  %AST.Literal{value: 1},
                  %AST.Literal{value: 2}
                ]
              }, _} =
               MacroExpander.expand(lst([id(:qq), int(42), tup([int(1), int(2)])]), env)
    end

    test "quote is not available in normal runtime interpreter context" do
      env = Interpreter.new_context()
      qq_form = lst([id(:quote), int(42)])

      assert_raise RuntimeError, ~r/variável não definida: quote/, fn ->
        Interpreter.eval(qq_form, env)
      end
    end
  end
end
