defmodule PipelineTest do
  use ExUnit.Case, async: true

  alias Core.AST.{Identifier, List, Literal, Module}

  test "runs a file with loose expressions end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def a 1)\n(+ a 2)")
  end

  test "runs a file with def-module end to end" do
    assert {:ok, _results, _env} = Pipeline.run("(def-module foo (def a 1))")
  end

  defp build!(code) do
    {:ok, tokens} = Parser.Lexer.run(code)
    {:ok, forms} = Parser.SyntaxAnalyzer.run(tokens)
    {:ok, modules} = Pipeline.identify_modules(forms)
    base = Core.Env.new()

    Enum.map(modules, fn module ->
      env = %{Core.Env.new(base) | current_module: module.name}
      {:ok, expanded, _env} = Midfield.MacroExpander.run(module, env)
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

  # Aguardando o MacroExpander consumir quote antes de entregar a AST ao checker.
  # test "quote bodies stay raw data through the pipeline" do
  #   assert [%Quote{body: %List{elements: [%Identifier{name: :def} | _]}}] =
  #            main_body("(quote (def a 1))")
  # end

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
end
