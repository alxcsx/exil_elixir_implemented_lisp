defmodule Pipeline do
  @moduledoc """
  Módulo principal que orquestra toda a compilação.
  """

  alias Core.Env

  def run(source, opts \\ []) do
    mode = Keyword.get(opts, :mode, :interpret)
    env = Keyword.get(opts, :env, Env.new())

    with {:ok, forms} <- parse(source),
         {:ok, modules} <- Midfield.ModuleManager.identify_modules(forms) do
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

  # --  Helpers

  defp parse(source) do
    with {:ok, tokens} <- Parser.Lexer.run(source),
         {:ok, forms} <- Parser.SyntaxAnalyzer.run(tokens) do
      {:ok, forms}
    end
  end

  defp run_backend(:interpret, ast, env), do: Backend.Interpreter.run(ast, env)
  defp run_backend(:compile, ast, env), do: Backend.CodeGen.run(ast, env)
end
