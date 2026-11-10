defmodule Core.RuntimeEnv do
  @moduledoc """
  Ambiente de execução (runtime) do interpretador.

  Gerencia o estado de execução com valores Elixir avaliados (`vars` e `defs`),
  reutilizando a resolução de escopo, imports e aliases de `Core.Env`.
  """

  alias Core.Env

  defstruct vars: %{},
            defs: %{},
            imports: [],
            aliases: %{},
            parent: nil,
            current_module: nil

  def new(opts \\ [])

  def new(%Core.RuntimeEnv{} = parent) do
    %Core.RuntimeEnv{
      parent: parent,
      current_module: parent.current_module,
      imports: parent.imports,
      aliases: parent.aliases,
      defs: parent.defs
    }
  end

  def new(%Env{} = compile_env), do: from_compile_env(compile_env)

  def new(opts) when is_list(opts) do
    %Core.RuntimeEnv{
      current_module: Keyword.get(opts, :current_module, :__main__),
      defs: Keyword.get(opts, :defs, %{})
    }
  end

  @doc "Cria um RuntimeEnv a partir do ambiente de compilação (Core.Env)."
  def from_compile_env(%Env{runtime_env: rt} = compile_env) do
    %Core.RuntimeEnv{
      current_module: compile_env.current_module || :__main__,
      imports: compile_env.imports,
      aliases: compile_env.aliases,
      vars: (rt && rt.vars) || %{},
      defs: (rt && rt.defs) || %{}
    }
  end

  # -- Variáveis locais

  def get_var(nil, _key), do: nil

  def get_var(%Core.RuntimeEnv{} = env, key) when is_atom(key) do
    case Env.fetch_lookup(env, :vars, key) do
      {:ok, val} -> val
      :error -> Env.resolve(env, :defs, key)
    end
  end

  def get_var(%Core.RuntimeEnv{} = env, key), do: Env.lookup(env, :vars, key)

  def put_var(%Core.RuntimeEnv{} = env, key, val),
    do: %{env | vars: Map.put(env.vars, key, val)}

  def put_vars(%Core.RuntimeEnv{} = env, new_vars),
    do: %{env | vars: Map.merge(env.vars, new_vars)}

  def has_var?(%Core.RuntimeEnv{} = env, key), do: not is_nil(get_var(env, key))

  # -- Definições de módulo

  def put_def(%Core.RuntimeEnv{} = env, name, val) do
    mod = env.current_module || :__main__
    Map.update!(env, :defs, &Map.put(&1, {mod, name}, val))
  end

  def get_def(%Core.RuntimeEnv{} = env, name), do: Env.resolve(env, :defs, name)
end
