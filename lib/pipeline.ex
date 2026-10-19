defmodule Pipeline do
  @moduledoc """
  Módulo principal que orquestra toda a compilação.
  """

  alias Core.AST.{Identifier, List, Module}
  alias Core.Env

  @arithmetic_names [:+, :-, :*, :/, :**]
  @arithmetic_binding %{type: :Any, arity: 2}

  def run(source, opts \\ []) do
    mode = Keyword.get(opts, :mode, :interpret)
    env = opts |> Keyword.get(:env, Env.new()) |> with_arithmetic()

    with {:ok, forms} <- parse(source),
         {:ok, modules} <- identify_modules(forms) do
      {:ok, Enum.map(modules, &compile_module(&1, mode, env)), env}
    end
  end

  def compile_module(module, mode, env) do
    module_env = %{Env.new(env) | current_module: module.name}
    {:ok, expanded, module_env} = Midfield.MacroExpander.run(module, module_env)
    {:ok, typed_ast, module_env} = Midfield.TypeChecker.run(expanded, module_env)
    {:ok, result, _module_env} = run_backend(mode, typed_ast, module_env)
    result
  end

  @doc "Divide as formas do parser em módulos; sobras viram :__main__."
  def identify_modules(forms) do
    {inner_modules_raw, loose_expressions} = Enum.split_with(forms, &def_module?/1)

    inner_modules =
      Enum.map(
        inner_modules_raw,
        fn %List{elements: [_kw, %Identifier{name: name} | body], meta: meta} ->
          %Module{name: name, body: body, meta: meta}
        end
      )

    modules =
      case loose_expressions do
        [] ->
          inner_modules

        _ ->
          inner_modules ++ [%Module{name: :__main__, body: loose_expressions, meta: %{line: 0}}]
      end

    {:ok, modules}
  end

  # --  Helpers

  defp with_arithmetic(env) do
    Enum.reduce(@arithmetic_names, env, fn name, current_env ->
      if Env.has_var?(current_env, name) do
        current_env
      else
        Env.put_var(current_env, name, @arithmetic_binding)
      end
    end)
  end

  defp parse(source) do
    with {:ok, tokens} <- Parser.Lexer.run(source),
         {:ok, forms} <- Parser.SyntaxAnalyzer.run(tokens) do
      {:ok, forms}
    end
  end

  defp def_module?(%List{elements: [%Identifier{name: :"def-module"} | _]}), do: true
  defp def_module?(_), do: false

  defp run_backend(:interpret, ast, env), do: Backend.Interpreter.run(ast, env)
  defp run_backend(:compile, ast, env), do: Backend.CodeGen.run(ast, env)
end
