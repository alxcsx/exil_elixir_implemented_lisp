defmodule Core.RuntimeEnv do
  @moduledoc """
  Ambiente de execução (runtime) do interpretador.

  Diferente do `Core.Env` (ambiente de compilação que rastreia módulos,
  macros, tipos e metadados de análise estática), o `RuntimeEnv` gerencia
  estritamente o estado de execução com valores Elixir avaliados:
  - `vars`: valores de variáveis no escopo léxico
  - `defs`: definições de módulo `{módulo, nome} => valor`
  - `imports`: módulos importados
  - `aliases`: aliases de módulos
  - `parent`: escopo léxico pai
  - `current_module`: módulo corrente
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

  def new(%Env{} = compile_env) do
    from_compile_env(compile_env)
  end

  def new(opts) when is_list(opts) do
    current_module = Keyword.get(opts, :current_module, :__main__)
    base_defs = Keyword.get(opts, :defs, default_defs())

    %Core.RuntimeEnv{
      current_module: current_module,
      defs: base_defs
    }
  end

  @doc "Cria um RuntimeEnv a partir do ambiente de compilação (Core.Env)."
  def from_compile_env(%Env{} = compile_env) do
    base_defs =
      if compile_env.runtime_env do
        compile_env.runtime_env.defs
      else
        default_defs()
      end

    base_vars =
      if compile_env.runtime_env do
        compile_env.runtime_env.vars
      else
        %{}
      end
      |> Map.merge(compile_env.vars)

    %Core.RuntimeEnv{
      current_module: compile_env.current_module || :__main__,
      imports: compile_env.imports,
      aliases: compile_env.aliases,
      vars: base_vars,
      defs: base_defs
    }
  end

  defp default_defs do
    Pipeline.base_env().runtime_env.defs
  end

  # -- Variáveis locais

  def get_var(nil, _key), do: nil

  def get_var(%Core.RuntimeEnv{} = env, key) when is_atom(key) do
    case fetch_lookup(env, :vars, key) do
      {:ok, val} -> val
      :error -> resolve(env, :defs, key)
    end
  end

  def get_var(%Core.RuntimeEnv{} = env, key), do: lookup(env, :vars, key)

  def put_var(%Core.RuntimeEnv{} = env, key, val) do
    %{env | vars: Map.put(env.vars, key, val)}
  end

  def put_vars(%Core.RuntimeEnv{} = env, new_vars) do
    %{env | vars: Map.merge(env.vars, new_vars)}
  end

  def has_var?(%Core.RuntimeEnv{} = env, key), do: not is_nil(get_var(env, key))

  # -- Definições de módulo

  def put_def(%Core.RuntimeEnv{} = env, name, val) do
    mod = env.current_module || :__main__
    Map.update!(env, :defs, &Map.put(&1, {mod, name}, val))
  end

  def get_def(%Core.RuntimeEnv{} = env, name), do: resolve(env, :defs, name)

  # -- Resolução interna

  defp resolve(%Core.RuntimeEnv{} = env, field, name) do
    case split_qualified(name) do
      {:qualified, prefix, local} ->
        case Map.get(env.aliases, prefix) do
          nil -> nil
          mod -> lookup(env, field, {mod, local})
        end

      :local ->
        lookup(env, field, {env.current_module, name}) ||
          lookup(env, field, {nil, name}) ||
          lookup(env, field, {:__main__, name}) ||
          lookup(env, field, {:Prelude, name}) ||
          lookup_imports(env, field, name)
    end
  end

  defp split_qualified(name) when is_atom(name) do
    {prefix, [local]} = name |> Atom.to_string() |> String.split("/") |> Enum.split(-1)

    if prefix == [] or local == "" or Enum.any?(prefix, &(&1 == "")) do
      :local
    else
      {:qualified, prefix |> Enum.join("/") |> String.to_atom(), String.to_atom(local)}
    end
  end

  defp split_qualified(_name), do: :local

  defp lookup_imports(env, field, name) do
    Enum.find_value(env.imports, fn mod -> lookup(env, field, {mod, name}) end)
  end

  defp lookup(env, field, key) do
    case fetch_lookup(env, field, key) do
      {:ok, val} -> val
      :error -> nil
    end
  end

  defp fetch_lookup(nil, _field, _key), do: :error

  defp fetch_lookup(env, field, key) do
    case Map.fetch(Map.fetch!(env, field), key) do
      {:ok, val} -> {:ok, val}
      :error -> fetch_lookup(env.parent, field, key)
    end
  end
end
