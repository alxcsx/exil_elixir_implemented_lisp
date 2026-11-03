defmodule PipelineTest do
  use ExUnit.Case, async: true

  alias Core.AST.{Identifier, List, Literal, Module, Tuple}
  alias Core.Env

  test "runs a file with loose expressions end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def a 1)\n(+ a 2)")
  end

  test "runs a file with def-module end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def-module foo (def a 1))")
  end

  test "env accumulates module definitions and imports resolve across modules" do
    assert {:ok, _results, env} =
             Pipeline.run("(def-module helpers (def-macro identity [x] x))")

    assert %{name: :identity} = Env.get_macro(env, :identity)

    assert {:ok, _results, env} =
             Pipeline.run("(def-module main (import helpers))", env: env)

    assert Env.has_macro?(env, :identity)
  end

  test "imports are scoped to each module" do
    assert {:ok, _results, _env} =
             Pipeline.run("""
             (def-module shared (def sum (fn [x] x)))
             (def-module a (import shared) (def x (sum 1)))
             (def-module b (import shared as s) (def y (s/sum 2)))
             """)

    assert {:error, message} =
             Pipeline.run("""
             (def-module shared (def sum (fn [x] x)))
             (def-module a (import shared))
             (def-module b (def y (sum 2)))
             """)

    assert message =~ "identificador não declarado"

    assert {:error, message} =
             Pipeline.run("""
             (def-module shared (def sum (fn [x] x)))
             (def-module a (import shared as s))
             (def-module b (def y (s/sum 2)))
             """)

    assert message =~ "identificador não declarado"
  end

  test "module defs resolve only via import" do
    assert {:ok, _results, env} =
             Pipeline.run("(def-module helpers (def inc (fn [x] (+ x 1))))")

    assert {:ok, _results, _env} =
             Pipeline.run(
               "(def-module main (import helpers) (+ (inc 1) 1))",
               env: env
             )
  end

  test "import as resolves prefixed calls" do
    assert {:ok, _results, env} =
             Pipeline.run("(def-module stdlib (def print (fn [x] x)))")

    assert {:ok, _results, _env} =
             Pipeline.run(
               "(def-module main (import stdlib as std) (std/print \"hi\"))",
               env: env
             )
  end

  test "modules are compiled in dependency order" do
    assert {:ok, _results, _env} =
             Pipeline.run("""
             (def-module main (import helpers) (def x (inc 1)))
             (def-module helpers (def inc (fn [n] (+ n 1))))
             """)
  end

  test "circular module dependencies are an error" do
    assert {:error, message} =
             Pipeline.run("""
             (def-module A (import B) (def x 1))
             (def-module B (import A) (def y 1))
             """)

    assert message =~ "dependência circular"
  end

  test "run_file derives the module name from the path" do
    dir = Path.join(System.tmp_dir!(), "tl_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".exil"), "")
    path = Path.join(dir, "math_utils.exl")
    File.write!(path, "(def base 1)\n(def-module Vec (def sum (fn [x] x)))")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, _results, env} = Pipeline.run_file(path)
    assert Env.get_def(env, :base)
  end

  test "errors carry the source file from the env" do
    dir = Path.join(System.tmp_dir!(), "tl_err_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".exil"), "")
    path = Path.join(dir, "bad.exl")
    File.write!(path, "unknown\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, message} = Pipeline.run_file(path)
    assert message =~ "bad.exl"
  end

  test "run_file resolves relative imports across directories" do
    dir = Path.join(System.tmp_dir!(), "tl_rel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "app"))
    File.mkdir_p!(Path.join(dir, "shared"))
    File.write!(Path.join(dir, ".exil"), "")

    File.write!(
      Path.join(dir, "app/main.exls"),
      "(import \"../shared/vec.exl\")\n(def out (sum 1))"
    )

    File.write!(Path.join(dir, "shared/vec.exl"), "(def sum (fn [x] (+ x 1)))")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, _results, env} = Pipeline.run_file(Path.join(dir, "app/main.exls"))
    assert Env.get_def(env, :out)
  end

  test "run_file on a script compiles script dependencies" do
    dir = Path.join(System.tmp_dir!(), "tl_scr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "main.exls"), "(import \"./util.exls\")\n(def out (helper 1))")
    File.write!(Path.join(dir, "util.exls"), "(def helper (fn [x] (+ x 1)))")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, _results, env} = Pipeline.run_file(Path.join(dir, "main.exls"))
    assert Env.get_def(env, :out)
  end

  defp build!(code) do
    {:ok, forms} = Parser.parse(code)
    {:ok, modules} = Midfield.ModuleManager.identify_modules(forms)
    base = Core.Env.new()

    Enum.map(modules, fn module ->
      env = %{Core.Env.new(base) | current_module: module.name}
      {:ok, expanded, _env} = Midfield.MacroExpander.run(module, env)
      {:ok, desugared} = Midfield.Desugar.run(expanded)
      desugared
    end)
  end

  defp main_body(code) do
    assert [%Module{name: :__main__, body: body}] = build!(code)
    body
  end

  test "special forms stay raw lists end to end" do
    assert [
             %List{
               elements: [%Identifier{name: :def}, %Identifier{name: :a}, %Literal{value: 1}]
             }
           ] = main_body("(def a 1)")
  end

  test "quote bodies are compiled into AST constructors by the macro expander" do
    assert [
             %List{
               elements: [
                 %List{elements: [%Identifier{name: :_ffi} | _]} | _
               ]
             }
           ] = main_body("(quote (def a 1))")

    assert {:ok, [quoted_def], _} = Pipeline.run("(quote (def a 1))")
    assert %List{elements: [%Identifier{name: :def}, %Identifier{name: :a}, %Literal{value: 1}]} = quoted_def
  end

  test "quote evaluates at runtime to first-class AST data structures" do
    assert {:ok, [%Identifier{name: :hello}], _} = Pipeline.run("(quote hello)")
    assert {:ok, [%Literal{type: :Int, value: 42}], _} = Pipeline.run("(quote 42)")
    assert {:ok, [%Tuple{elements: [%Literal{value: 1}, %Literal{value: 2}]}], _} =
             Pipeline.run("(quote [1 2])")

    code = """
    (def code (quote (+ 10 20)))
    code
    """
    assert {:ok, [%List{elements: [%Identifier{name: :+}, %Literal{value: 10}, %Literal{value: 20}]}], _} =
             Pipeline.run(code)
  end

  test "def-macro forms are pruned by the expander and never reach the output" do
    assert [%Module{name: :__main__, body: [def_form]}] =
             build!("(def-macro identity [x] x)\n(def a 1)")

    assert %List{elements: [%Identifier{name: :def} | _]} = def_form
  end

  test "def-macro with parenthesis syntax raises error" do
    assert {:error, message} = Pipeline.run("(def-macro identity (x) x)")
    assert message =~ "sintaxe inválida para def-macro"
  end

  test "no :__main__ module when the file has only def-module forms" do
    assert [%Module{name: :foo}, %Module{name: :bar}] =
             build!("(def-module foo (def a 1))(def-module bar (def b 2))")
  end

  test "def-module splits into modules, loose expressions go to :__main__" do
    assert [
             %Module{
               name: :foo,
               body: [
                 %List{elements: [%Identifier{name: :def} | _]},
                 %List{elements: [%Identifier{name: :+} | _]}
               ]
             },
             %Module{name: :__main__, body: [%List{elements: [%Identifier{name: :bar}]}]}
           ] =
             build!("""
             (def-module foo
               (def a 1)
               (+ 1 2))
             (bar)
             """)
  end

  describe "REPL-style sequential imports" do
    test "imports persist across consecutive evaluations with as" do
      env = Pipeline.base_env()
      assert {:ok, _results, env} = Pipeline.run("(import Ast as ast)", env: env)
      assert {:ok, [res], env} = Pipeline.run("(ast/id :val)", env: env)
      assert %Core.AST.Identifier{name: :val} = res

      assert {:ok, [res2], _env} = Pipeline.run("(ast/int 42)", env: env)
      assert %Core.AST.Literal{type: :Int, value: 42} = res2
    end

    test "unqualified import persists across consecutive evaluations" do
      env = Pipeline.base_env()
      assert {:ok, _results, env} = Pipeline.run("(import Ast)", env: env)
      assert {:ok, [res], _env} = Pipeline.run("(id :val3)", env: env)
      assert %Core.AST.Identifier{name: :val3} = res
    end
  end

  describe "Runtime reflection and subtyping (<:, type-of, instance-of?)" do
    test "type-of returns canonical runtime types" do
      assert {:ok, [:Int], _} = Pipeline.run("(type-of 42)")
      assert {:ok, [:Float], _} = Pipeline.run("(type-of 3.14)")
      assert {:ok, [:Str], _} = Pipeline.run("(type-of \"hello\")")
      assert {:ok, [{:Symbol, :status}], _} = Pipeline.run("(type-of :status)")
      assert {:ok, [{:Tuple, [:Int, :Int]}], _} = Pipeline.run("(type-of [1 2])")
      assert {:ok, [{:List, :Int}], _} = Pipeline.run("(type-of (list 1 2 3))")
      assert {:ok, [{:Map, %{a: :Int, b: :Str}}], _} = Pipeline.run("(type-of {:a 1 :b \"hi\"})")
    end

    test "dynamic <: evaluates at runtime" do
      assert {:ok, [true], _} = Pipeline.run("(<: (type-of 42) Int)")
      assert {:ok, [false], _} = Pipeline.run("(<: (type-of \"hello\") Int)")
      assert {:ok, [true], _} = Pipeline.run("(<: (type-of 42) Num)")
      assert {:ok, [true], _} = Pipeline.run("(<: (type-of 42) (type-of 100))")
      assert {:ok, [false], _} = Pipeline.run("(<: (type-of 42) (type-of \"hello\"))")
    end

    test "instance-of? macro with primitives and union types" do
      assert {:ok, [true], _} = Pipeline.run("(instance-of? 42 Int)")
      assert {:ok, [false], _} = Pipeline.run("(instance-of? \"hello\" Int)")
      assert {:ok, [true], _} = Pipeline.run("(instance-of? 42 Num)")
      assert {:ok, [true], _} = Pipeline.run("(instance-of? 3.14 Num)")
      assert {:ok, [false], _} = Pipeline.run("(instance-of? \"hello\" Num)")
    end

    test "instance-of? with custom records and structural subtyping" do
      code = """
      (def-type Plane {:id Int :model Str})
      (def p {:id 1 :model "737" :airline "Gol"})
      (def incomplete {:model "737"})
      (list (instance-of? p Plane) (instance-of? incomplete Plane))
      """

      assert {:ok, [[true, false]], _} = Pipeline.run(code)
    end

    test "instance-of? with generic def-type" do
      code = """
      (def-type (Box [T]) {:val T})
      (def b {:val 42})
      (list (instance-of? b (Box Int)) (instance-of? b (Box Str)))
      """

      assert {:ok, [[true, false]], _} = Pipeline.run(code)
    end

    test "instance-of? inside functions and conditionals" do
      code = """
      (def classify (fn [x]
        (if (instance-of? x Int) :is_int
        (if (instance-of? x Str) :is_str :other))))
      (list (classify 10) (classify "hello") (classify :foo))
      """

      assert {:ok, [[:is_int, :is_str, :other]], _} = Pipeline.run(code)
    end
  end

  describe "defn macro in Prelude" do
    test "defines functions with single expression body" do
      code = """
      (defn add [x y] (+ x y))
      (add 10 32)
      """
      assert {:ok, [42], _} = Pipeline.run(code)
    end

    test "defines functions with multiple expressions in body" do
      code = """
      (defn calculate [x]
        (+ x 1)
        (let [y (+ x 10)]
          (* y 2)))
      (calculate 5)
      """
      assert {:ok, [30], _} = Pipeline.run(code)
    end

    test "supports variadic parameters in defn" do
      code = """
      (defn collect [head | tail] [head tail])
      (collect 1 2 3)
      """
      assert {:ok, [{1, [2, 3]}], _} = Pipeline.run(code)
    end

    test "supports recursive functions in defn" do
      code = """
      (defn fact [n]
        (if (<= n 1) 1 (* n (fact (- n 1)))))
      (fact 5)
      """
      assert {:ok, [120], _} = Pipeline.run(code)
    end

    test "integrates with spec definitions" do
      code = """
      (spec double (-> [Int] Num))
      (defn double [x] (+ x x))
      (double 21)
      """
      assert {:ok, [42], _} = Pipeline.run(code)
    end

    test "not defined via defn inside Prelude works as expected" do
      assert {:ok, [false], _} = Pipeline.run("(not :true)")
      assert {:ok, [true], _} = Pipeline.run("(not :false)")
      assert {:ok, [false], _} = Pipeline.run("(not 1)")
      assert {:ok, [false], _} = Pipeline.run("(not \"hello\")")
    end
  end

  describe "Prelude operators and functions" do
    test "comparison operators !=, >, <=, >=" do
      code = """
      (list
        (!= 1 2)
        (!= 2 2)
        (> 5 3)
        (> 3 5)
        (<= 3 3)
        (<= 3 4)
        (<= 4 3)
        (>= 5 5)
        (>= 6 5)
        (>= 4 5)
      )
      """
      assert {:ok, [[true, false, true, false, true, true, false, true, true, false]], _} = Pipeline.run(code)
    end

    test "structural equality on nested structures" do
      code = """
      (list
        (== [1 {:a [2 3]}] [1 {:a [2 3]}])
        (== [1 {:a [2 3]}] [1 {:a [2 4]}])
        (== :nil :false)
      )
      """
      assert {:ok, [[true, false, false]], _} = Pipeline.run(code)
    end
  end
end
