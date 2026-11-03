defmodule Core.Env do
  @moduledoc """
  Registro de variáveis, definições de módulo, macros, tipos e módulos.

  Variáveis são léxicas; definições de módulo usam chave {módulo, nome}.
  Imports e aliases pertencem ao módulo; escopos léxicos internos os herdam.
  `file` é o arquivo da fonte atual, usado em diagnósticos.
  """

  defstruct vars: %{},
            defs: %{},
            types: %{},
            macros: %{},
            imports: [],
            aliases: %{},
            modules: %{},
            loaded: MapSet.new(),
            discovered: MapSet.new(),
            defined: MapSet.new(),
            opts: [],
            parent: nil,
            current_module: nil,
            file: nil,
            runtime_env: nil

  def new(%Core.Env{} = parent) do
    %Core.Env{
      parent: parent,
      opts: parent.opts,
      current_module: parent.current_module,
      file: parent.file,
      imports: parent.imports,
      aliases: parent.aliases,
      runtime_env: parent.runtime_env
    }
  end

  def new(opts) when is_list(opts) do
    engine = Keyword.get(opts, :macro_engine, :interpreter)
    %Core.Env{parent: nil, opts: [macro_engine: engine]}
  end

  def new(), do: new([])

  # -- Variáveis

  def get_var(nil, _key), do: nil

  def get_var(env, key) when is_atom(key) do
    lookup(env, :vars, key) || resolve(env, :defs, key)
  end

  def get_var(env, key), do: lookup(env, :vars, key)

  def put_vars(env, new_vars), do: %{env | vars: Map.merge(env.vars, new_vars)}
  def put_var(env, key, val), do: %{env | vars: Map.put(env.vars, key, val)}
  def has_var?(env, key), do: not is_nil(get_var(env, key))

  # -- Definições de módulo {módulo, nome}

  def put_def(env, name, val), do: put_module_level(env, :defs, name, val)
  def get_def(env, name), do: resolve(env, :defs, name)

  def get_macro(env, name), do: resolve(env, :macros, name)
  def get_type(env, name), do: resolve(env, :types, name)
  def get_module_type(env, name), do: lookup(env, :types, {env.current_module, name})
  def has_macro?(env, name), do: not is_nil(resolve(env, :macros, name))
  def has_type?(env, name), do: not is_nil(resolve(env, :types, name))
  def put_macro(env, name, val), do: put_module_level(env, :macros, name, val)
  def put_type(env, name, val), do: put_module_level(env, :types, name, val)

  # -- Imports e Aliases

  def import_module(env, module) do
    %{
      env
      | imports: Enum.uniq(env.imports ++ [module]),
        aliases: Map.put_new(env.aliases, module, module)
    }
  end

  def alias_module(env, alias_name, module),
    do: %{env | aliases: Map.put(env.aliases, alias_name, module)}

  # -- Registro de módulos e estado de carregamento

  def put_module(env, name, info), do: %{env | modules: Map.put(env.modules, name, info)}
  def get_module(env, name), do: lookup(env, :modules, name)
  def has_module?(env, name), do: not is_nil(lookup(env, :modules, name))

  def mark_discovered(env, dir), do: %{env | discovered: MapSet.put(env.discovered, dir)}
  def discovered?(env, dir), do: member_in_chain?(env, :discovered, dir)

  def mark_loaded(env, path), do: %{env | loaded: MapSet.put(env.loaded, path)}
  def loaded?(env, path), do: member_in_chain?(env, :loaded, path)

  def mark_defined(env, name), do: %{env | defined: MapSet.put(env.defined, name)}
  def defined?(env, name), do: member_in_chain?(env, :defined, name)

  def has_parent?(env), do: env.parent != nil

  # -- Resolução compartilhada (usada por Core.Env e Core.RuntimeEnv)

  def put_module_level(env, field, name, val) do
    Map.update!(env, field, &Map.put(&1, {env.current_module, name}, val))
  end

  def resolve(env, field, name) do
    case split_qualified(name) do
      {:qualified, prefix, local} ->
        case find_alias(env, prefix) do
          nil -> nil
          mod -> lookup(env, field, {mod, local})
        end

      :local ->
        lookup(env, field, {env.current_module, name}) ||
          lookup(env, field, {nil, name}) ||
          lookup(env, field, {:Prelude, name}) ||
          lookup_imports(env, field, name)
    end
  end

  def lookup(env, field, key) do
    case fetch_lookup(env, field, key) do
      {:ok, val} -> val
      :error -> nil
    end
  end

  def fetch_lookup(nil, _field, _key), do: :error

  def fetch_lookup(env, field, key) do
    case Map.fetch(Map.fetch!(env, field), key) do
      {:ok, val} -> {:ok, val}
      :error -> fetch_lookup(env.parent, field, key)
    end
  end

  defp member_in_chain?(nil, _field, _item), do: false

  defp member_in_chain?(env, field, item) do
    MapSet.member?(Map.fetch!(env, field), item) or member_in_chain?(env.parent, field, item)
  end

  defp find_alias(nil, _prefix), do: nil

  defp find_alias(env, prefix) do
    Map.get(env.aliases, prefix) || find_alias(env.parent, prefix)
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

  defp lookup_imports(nil, _field, _name), do: nil

  defp lookup_imports(env, field, name) do
    Enum.find_value(env.imports, fn mod -> lookup(env, field, {mod, name}) end) ||
      lookup_imports(env.parent, field, name)
  end
end
