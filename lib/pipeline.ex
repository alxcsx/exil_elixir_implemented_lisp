defmodule Pipeline do
  @moduledoc """
  Orquestra a compilação.

  `run/2` recebe a fonte e as opções (`:env`, `:mode`, `:root`, `:std`).
  O arquivo da fonte e o módulo corrente vêm do env; sem arquivo, a fonte
  é um script com raiz no cwd.
  """

  alias Core.Env

  def run(source), do: run(source, [])

  def run(source, opts) when is_list(opts) do
    env = Keyword.get(opts, :env, Env.new())
    mode = Keyword.get(opts, :mode, :interpret)

    with {:ok, plan, env} <- Midfield.ModuleManager.load_plan(source, env, opts) do
      case compile_plan(plan, mode, env) do
        {:ok, results, env} -> {:ok, results, %{env | file: nil}}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Lê o arquivo e compila com o env apontando para ele."
  def run_file(path, opts \\ []) do
    path = Path.expand(path)

    with {:ok, source} <- File.read(path) do
      env = Keyword.get(opts, :env, Env.new())
      run(source, Keyword.put(opts, :env, %{env | file: path}))
    end
  end

  @doc "Compila um módulo; devolve {:ok, resultado, env} ou {:error, motivo}."
  def compile_module(module, mode, env) do
    module_env = %{
      Env.new(env)
      | current_module: module.name,
        file: module.meta[:file],
        imports: [],
        aliases: %{}
    }

    with {:ok, expanded, module_env} <- Midfield.MacroExpander.run(module, module_env),
         {:ok, typed_ast, module_env} <- Midfield.TypeChecker.run(expanded, module_env),
         {:ok, result, module_env} <- run_backend(mode, typed_ast, module_env) do
      {:ok, result, module_env}
    end
  end

  # --  Helpers

  defp compile_plan(plan, mode, env) do
    result =
      Enum.reduce_while(plan, {:ok, [], env}, fn {module, path}, {:ok, results, env} ->
        case compile_module(module, mode, env) do
          {:ok, result, env} ->
            env = env |> Env.mark_defined(module.name) |> mark_loaded(path)
            {:cont, {:ok, [result | results], env}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, results, env} -> {:ok, Enum.reverse(results), env}
      {:error, _} = error -> error
    end
  end

  defp mark_loaded(env, nil), do: env
  defp mark_loaded(env, path), do: Env.mark_loaded(env, path)

  defp run_backend(:interpret, ast, env), do: Backend.Interpreter.run(ast, env)
  defp run_backend(:compile, ast, env), do: Backend.CodeGen.run(ast, env)
end
