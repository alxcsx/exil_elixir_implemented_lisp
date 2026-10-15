defmodule Midfield.ModuleManagerTest do
  use ExUnit.Case, async: true

  alias Core.AST.Module
  alias Core.Env
  alias Midfield.ModuleManager

  defp write_tree(files) do
    dir = Path.join(System.tmp_dir!(), "typed_lisp_#{System.unique_integer([:positive])}")

    Enum.each(files, fn {rel, source} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end)

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp parse(source) do
    {:ok, tokens} = Parser.Lexer.run(source)
    Parser.SyntaxAnalyzer.run(tokens)
  end

  defp plan(dir, rel, opts \\ []) do
    path = Path.join(dir, rel)
    ModuleManager.load_plan(File.read!(path), %{Env.new() | file: path}, opts)
  end

  defp modules!(source, file_module \\ nil) do
    {:ok, forms} = parse(source)
    {:ok, modules} = ModuleManager.identify_modules(forms, file_module)
    modules
  end

  describe "discover/2" do
    test "registers .exl files under the path-derived name" do
      dir =
        write_tree(%{
          "foo.exl" => "(def x 1)",
          "nested/bar.exl" => "(def y 1)"
        })

      assert {:ok, env} = ModuleManager.discover(dir, Env.new())

      assert %{path: foo_path} = Env.get_module(env, :Foo)
      assert Path.basename(foo_path) == "foo.exl"
      assert %{path: bar_path} = Env.get_module(env, :"Nested/Bar")
      assert Path.basename(bar_path) == "bar.exl"
      refute Env.has_module?(env, :Missing)
    end

    test "rejects invalid file names" do
      dir = write_tree(%{"3x.exl" => ""})

      assert {:error, message} = ModuleManager.discover(dir, Env.new())
      assert message =~ "inválido"
    end

    test "rejects two files deriving the same module name" do
      dir = write_tree(%{"math_utils.exl" => "(def a 1)", "math-utils.exl" => "(def b 2)"})

      assert {:error, message} = ModuleManager.discover(dir, Env.new())
      assert message =~ "MathUtils"
    end

    test "rejects two files declaring the same module" do
      dir =
        write_tree(%{
          "a.exl" => "(def-module Shared (def x 1))",
          "b.exl" => "(def-module Shared (def y 1))"
        })

      assert {:error, message} = ModuleManager.discover(dir, Env.new())
      assert message =~ "Shared"
    end
  end

  describe "order/1" do
    test "dependencies compile before dependents" do
      modules =
        modules!("""
        (def-module B (import A) (def y 1))
        (def-module A (def x 1))
        """)

      assert {:ok, ordered} = ModuleManager.order(modules)
      assert Enum.map(ordered, & &1.name) == [:A, :B]
    end

    test "imports outside the unit are ignored" do
      modules = modules!("(def-module A (import AlreadyCompiled) (def x 1))")

      assert {:ok, [%Module{name: :A}]} = ModuleManager.order(modules)
    end

    test "reports a cycle with its path" do
      modules =
        modules!("""
        (def-module A (import B) (def x 1))
        (def-module B (import A) (def y 1))
        """)

      assert {:error, message} = ModuleManager.order(modules)
      assert message == "dependência circular: A -> B -> A"
    end

    test "reports self import" do
      modules = modules!("(def-module A (import A) (def x 1))")

      assert {:error, message} = ModuleManager.order(modules)
      assert message == "dependência circular: A -> A"
    end
  end

  describe "derive_name/2" do
    test "camel cases each path segment" do
      assert {:ok, :"Std/MathUtils"} = ModuleManager.derive_name("std/math_utils.exl", ".")

      assert {:ok, :"Std/MathUtils/Vec"} =
               ModuleManager.derive_name("std/math_utils/vec.exl", ".")
    end

    test "arquivo fora da raiz é erro" do
      assert {:error, message} = ModuleManager.derive_name("/outro/lugar/x.exl", "/raiz")
      assert message =~ "fora da raiz"
    end
  end

  describe "identify_modules/2" do
    test "declared name is final, loose forms go to the file module" do
      {:ok, forms} = parse("(def base 1)\n(def-module Vec (def sum (fn [x] x)))")

      assert {:ok, modules} = ModuleManager.identify_modules(forms, :"Std/MathUtils")
      assert Enum.map(modules, & &1.name) == [:Vec, :"Std/MathUtils"]
    end

    test "nested modules compose by nesting and leave the parent body" do
      {:ok, forms} = parse("(def-module Outer (def-module Inner (def f 1)) (def g 2))")

      assert {:ok, modules} = ModuleManager.identify_modules(forms, nil)
      assert [%Module{name: :"Outer/Inner"}, %Module{name: :Outer}] = modules

      assert %Module{body: [%Core.AST.List{} = inner]} = Enum.at(modules, 0)
      assert %Core.AST.List{elements: [%Core.AST.Identifier{name: :def}, _, _]} = inner

      assert %Module{body: [%Core.AST.List{} = outer]} = Enum.at(modules, 1)
      assert %Core.AST.List{elements: [%Core.AST.Identifier{name: :def} | _]} = outer
    end

    test "pathless source keeps global module names" do
      {:ok, forms} = parse("(def-module Vec (def sum (fn [x] x)))")

      assert {:ok, modules} = ModuleManager.identify_modules(forms, nil)
      assert Enum.map(modules, & &1.name) == [:Vec]
    end

    test "declared name is preserved verbatim" do
      {:ok, forms} = parse("(def-module Std/MathUtils (def base 1))")

      assert {:ok, modules} = ModuleManager.identify_modules(forms, :"Std/MathUtils")
      assert Enum.map(modules, & &1.name) == [:"Std/MathUtils"]
    end

    test "duplicate module names are an error" do
      {:ok, forms} = parse("(def-module Vec (def a 1))\n(def-module Vec (def b 2))")

      assert {:error, message} = ModuleManager.identify_modules(forms, :"Std/MathUtils")
      assert message =~ "Vec"
    end
  end

  describe "load_plan/4" do
    test "script imports modules by relative path" do
      dir =
        write_tree(%{
          ".exil" => "",
          "app/main.exls" => "(import \"../shared/vec.exl\")",
          "shared/vec.exl" => "(def sum (fn [x] x))"
        })

      assert {:ok, plan, _env} = plan(dir, "app/main.exls")

      assert Enum.map(plan, fn {module, _path} -> module.name end) ==
               [:"Shared/Vec", :Main]
    end

    test "module files import by registry name" do
      dir =
        write_tree(%{
          ".exil" => "",
          "app/by_name.exl" => "(import Shared/Vec)",
          "shared/vec.exl" => "(def sum (fn [x] x))"
        })

      assert {:ok, plan, _env} = plan(dir, "app/by_name.exl")

      assert Enum.map(plan, fn {module, _path} -> module.name end) ==
               [:"Shared/Vec", :"App/ByName"]
    end

    test "module files reject path imports" do
      dir = write_tree(%{".exil" => "", "main.exl" => "(import \"./other\")"})

      assert {:error, message} = plan(dir, "main.exl")

      assert message =~ "só em arquivo .exls"
    end

    test "scripts import other scripts by basename" do
      dir =
        write_tree(%{
          "main.exls" => "(import \"./util.exls\")\n(def out (helper 1))",
          "util.exls" => "(def helper (fn [x] x))"
        })

      assert {:ok, plan, _env} = plan(dir, "main.exls")

      assert Enum.map(plan, fn {module, _path} -> module.name end) == [:Util, :Main]
    end

    test "two scripts with the same basename are an error" do
      dir =
        write_tree(%{
          "main.exls" => "(import \"./a/util.exls\")\n(import \"./b/util.exls\")",
          "a/util.exls" => "(def f (fn [x] x))",
          "b/util.exls" => "(def g (fn [x] x))"
        })

      assert {:error, message} = plan(dir, "main.exls")
      assert message =~ "módulo duplicado: Util"
    end

    test "scripts resolve standard imports from :std" do
      dir =
        write_tree(%{
          "main.exls" => "(import Std/Io)\n(def out (show 1))",
          "std/io.exl" => "(def show (fn [x] x))"
        })

      assert {:ok, plan, _env} = plan(dir, "main.exls", std: dir)

      assert Enum.map(plan, fn {module, _path} -> module.name end) == [:"Std/Io", :Main]
    end

    test "reports cycles across files" do
      dir =
        write_tree(%{
          ".exil" => "",
          "a.exl" => "(import B)",
          "b.exl" => "(import A)"
        })

      assert {:error, message} = plan(dir, "a.exl")

      assert message == "dependência circular: a.exl -> b.exl -> a.exl"
    end

    test "rejects unknown module names" do
      dir = write_tree(%{".exil" => "", "main.exl" => "(import Nope)"})

      assert {:error, message} = plan(dir, "main.exl")

      assert message =~ "módulo desconhecido: Nope"
    end

    test "source without file resolves paths from :root" do
      dir = write_tree(%{"util.exl" => "(def helper (fn [x] x))"})

      assert {:ok, plan, _env} =
               ModuleManager.load_plan("(import \"./util.exl\")", Env.new(), root: dir)

      assert Enum.map(plan, fn {module, _path} -> module.name end) == [:Util, :__main__]
    end
  end

  describe "root_for/2" do
    test "sobe até o .exil mais próximo, senão cai no diretório do arquivo" do
      dir = write_tree(%{".exil" => "", "src/app/main.exl" => ""})

      assert {:ok, ^dir} = ModuleManager.root_for(Path.join(dir, "src/app/main.exl"), [])
      assert {:ok, ^dir} = ModuleManager.root_for("/qualquer/outro.exl", root: dir)
      assert {:ok, "/qualquer"} = ModuleManager.root_for("/qualquer/sem_marcador.exl", [])
    end
  end
end
