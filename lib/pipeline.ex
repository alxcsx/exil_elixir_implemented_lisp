defmodule Pipeline do
  @moduledoc """
  Orquestra o pipeline de compilação:

      Código Fonte
          │
          ▼  1. Parse (Parser.Lexer -> Parser.SyntaxAnalyzer)
      AST Bruta
          │
          ▼  2. Module Identification (Midfield.ModuleManager)
      Módulos & Plano de Compilação
          │
          ▼  3. Desugar (Parser.Desugar)
      AST Normalizada
          │
          ▼  4. Macro Expansion (Midfield.MacroExpander)
      AST Expandida
          │
          ▼  5. Type Check (Midfield.TypeChecker)
      AST Tipada
          │
          ▼  6. Backend (Backend.Interpreter / Backend.CodeGen)
      Resultado da Execução / Bytecode
  """

  alias Core.Env

  @default_std Path.expand("stdlib", __DIR__)
  @prelude_file Path.join(@default_std, "prelude.exl")

  def base_env do
    {:ok, _, env} =
      run_file(@prelude_file, env: %{Env.new() | runtime_env: %Core.RuntimeEnv{}}, std: nil)

    env
  end

  def run(source), do: run(source, [])

  def run(source, opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :std, default_std())
    env = Keyword.get_lazy(opts, :env, &base_env/0)
    mode = Keyword.get(opts, :mode, :interpret)

    with {:ok, forms} <- Parser.parse(source),
         {:ok, plan, env} <- Midfield.ModuleManager.build_plan(forms, env, opts),
         {:ok, results, env} <- compile_plan(plan, mode, env) do
      {:ok, results, %{env | file: nil}}
    end
  end

  @doc "Lê o arquivo e compila com o env apontando para ele."
  def run_file(path, opts \\ []) do
    path = Path.expand(path)
    opts = Keyword.put_new(opts, :std, default_std())

    with {:ok, source} <- File.read(path) do
      env = Keyword.get_lazy(opts, :env, &base_env/0)
      run(source, Keyword.put(opts, :env, %{env | file: path}))
    end
  end

  defp default_std do
    if File.dir?(@default_std), do: @default_std, else: nil
  end

  @doc """
  Compila um módulo através das fases:
  3. Desugar -> 4. Macro Expansion -> 5. Type Check -> 6. Backend
  """
  def compile_module(module, mode, env, opts \\ []) do
    is_entry = Keyword.get(opts, :is_entry, module.name == (env.current_module || :__main__))

    module_env =
      %{
        Env.new(env)
        | current_module: module.name,
          file: module.meta[:file],
          imports: if(is_entry, do: env.imports, else: []),
          aliases: if(is_entry, do: env.aliases, else: %{}),
          runtime_env: env.runtime_env
      }

    with {:ok, desugared} <- Parser.Desugar.run(module),
         {:ok, expanded, module_env} <- Midfield.MacroExpander.run(desugared, module_env),
         {:ok, typed_ast, module_env} <- Midfield.TypeChecker.run(expanded, module_env),
         {:ok, result, module_env} <- run_backend(mode, typed_ast, module_env) do
      {:ok, result, module_env}
    end
  end

  # --  Helpers

  defp compile_plan(plan, mode, env) do
    entry_module =
      case List.last(plan) do
        {%Core.AST.Module{name: name}, _} -> name
        _ -> env.current_module || :__main__
      end

    Enum.reduce_while(plan, {:ok, [], env}, fn {module, path}, {:ok, acc, current_env} ->
      is_entry = module.name == entry_module

      case compile_module(module, mode, current_env, is_entry: is_entry) do
        {:ok, result, mod_env} ->
          new_env =
            if is_entry do
              mod_env
            else
              %{
                mod_env
                | current_module: current_env.current_module,
                  file: current_env.file,
                  imports: current_env.imports,
                  aliases: current_env.aliases
              }
            end

          new_env = Env.mark_defined(new_env, module.name)
          new_env = if path, do: Env.mark_loaded(new_env, path), else: new_env
          {:cont, {:ok, [result | acc], new_env}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results, env} -> {:ok, Enum.reverse(results), env}
      {:error, _} = error -> error
    end
  end

  defp run_backend(:interpret, ast, env), do: Backend.Interpreter.run(ast, env)
  defp run_backend(:compile, ast, env), do: Backend.CodeGen.run(ast, env)
end
