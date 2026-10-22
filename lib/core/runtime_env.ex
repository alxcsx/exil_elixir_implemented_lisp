defmodule Core.RuntimeEnv do
  @moduledoc """
  Ambiente de execução (runtime) do interpretador.

  Diferente do `Core.Env` (ambiente de build/compilação que rastreia módulos,
  macros, tipos e metadados de análise estática), o `RuntimeEnv` gerencia
  estritamente o estado de execução:
  - `vars`: valores de variáveis no escopo léxico
  - `defs`: definições de módulo `{módulo, nome} => valor`
  - `imports`: módulos importados
  - `aliases`: aliases de módulos
  - `compile_env`: referência ao ambiente de compilação
  - `macro_handlers`: funções de apoio injetadas temporariamente durante a avaliação de macros (ex: `:quote`)
  - `parent`: escopo léxico pai
  - `current_module`: módulo corrente
  """

  alias Core.Env

  defstruct vars: %{},
            defs: %{},
            imports: [],
            aliases: %{},
            compile_env: nil,
            macro_handlers: %{},
            parent: nil,
            current_module: nil

  def new(opts \\ [])

  def new(%Core.RuntimeEnv{} = parent) do
    %Core.RuntimeEnv{
      parent: parent,
      current_module: parent.current_module,
      compile_env: parent.compile_env,
      imports: parent.imports,
      aliases: parent.aliases,
      macro_handlers: parent.macro_handlers,
      defs: parent.defs
    }
  end

  def new(%Env{} = compile_env) do
    from_compile_env(compile_env)
  end

  def new(opts) when is_list(opts) do
    compile_env = Keyword.get(opts, :compile_env)
    current_module = Keyword.get(opts, :current_module, :__main__)
    base_defs = Keyword.get(opts, :defs, Core.Prelude.runtime_defs())

    %Core.RuntimeEnv{
      compile_env: compile_env,
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
        Core.Prelude.runtime_defs()
      end

    base_macro_handlers =
      if compile_env.runtime_env do
        compile_env.runtime_env.macro_handlers
      else
        %{}
      end

    base_vars =
      if compile_env.runtime_env do
        compile_env.runtime_env.vars
      else
        %{}
      end
      |> Map.merge(compile_env.vars)

    %Core.RuntimeEnv{
      compile_env: compile_env,
      current_module: compile_env.current_module || :__main__,
      imports: compile_env.imports,
      aliases: compile_env.aliases,
      vars: base_vars,
      defs: base_defs,
      macro_handlers: base_macro_handlers
    }
  end

  # -- Variáveis locais

  def get_var(nil, _key), do: nil

  def get_var(%Core.RuntimeEnv{} = env, key) when is_atom(key) do
    lookup(env, :vars, key) || resolve(env, :defs, key)
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

  # -- Handlers de macro (injetados temporariamente durante expansão de macros)

  def put_macro_handler(%Core.RuntimeEnv{} = env, name, handler) do
    %{env | macro_handlers: Map.put(env.macro_handlers, name, handler)}
  end

  def get_macro_handler(nil, _name), do: :error

  def get_macro_handler(%Core.RuntimeEnv{} = env, name) do
    case Map.fetch(env.macro_handlers, name) do
      {:ok, handler} -> {:ok, handler}
      :error -> get_macro_handler(env.parent, name)
    end
  end

  # Fallback caso receba Core.Env
  def get_macro_handler(%Env{} = env, name) do
    if env.runtime_env do
      get_macro_handler(env.runtime_env, name)
    else
      :error
    end
  end

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
          lookup(env, field, {:prelude, name}) ||
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

  defp lookup(nil, _field, _key), do: nil

  defp lookup(env, field, key) do
    case Map.fetch(Map.fetch!(env, field), key) do
      {:ok, val} -> val
      :error -> lookup(env.parent, field, key)
    end
  end
end
