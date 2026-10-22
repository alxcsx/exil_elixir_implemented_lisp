defmodule PipelineTest do
  use ExUnit.Case, async: true

  alias Core.AST.{Identifier, List, Literal, Module}
  alias Core.Env

  test "runs a file with loose expressions end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def a 1)\n(+ a 2)")
  end

  test "runs a file with def-module end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def-module foo (def a 1))")
  end

  test "env accumulates module definitions and imports resolve across modules" do
    assert {:ok, _results, env} =
             Pipeline.run("(def-module helpers (defmacro identity (x) x))")

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
      {:ok, desugared} = Parser.Desugar.run(module)
      {:ok, expanded, _env} = Midfield.MacroExpander.run(desugared, env)
      expanded
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

  test "quote bodies stay raw data through the pipeline" do
    assert [
             %List{
               elements: [
                 %Identifier{name: :quote},
                 %List{elements: [%Identifier{name: :def} | _]}
               ]
             }
           ] = main_body("(quote (def a 1))")
  end

  test "defmacro forms are pruned by the expander and never reach the output" do
    # defmacro com args em parênteses também é reconhecido e podado
    assert [%Module{name: :__main__, body: [def_form]}] =
             build!("(defmacro identity (x) x)\n(def a 1)")

    assert %List{elements: [%Identifier{name: :def} | _]} = def_form
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
end
