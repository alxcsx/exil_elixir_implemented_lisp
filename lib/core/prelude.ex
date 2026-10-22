defmodule Core.Prelude do
  @moduledoc """
  Biblioteca padrão (Prelude) do TypedLisp.

  Define tipos base (como Bool = (u :true :false)) e operações primitivas
  de runtime (aritmética, comparações, lógica e coleções).
  """

  alias Core.AST.Literal
  alias Core.Env

  @bool_type {:Union, [{:Symbol, true}, {:Symbol, false}]}

  @types %{
    Bool: @bool_type,
    bool: @bool_type
  }

  @type_bindings %{
    :+ => %{type: :Any, arity: 2},
    :- => %{type: :Any, arity: 2},
    :* => %{type: :Any, arity: 2},
    :/ => %{type: :Any, arity: 2},
    :** => %{type: :Any, arity: 2},
    :== => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :!= => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :< => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :> => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :<= => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :>= => %{type: {:Fn, [:Any, :Any], @bool_type}, arity: 2},
    :not => %{type: {:Fn, [:Any], @bool_type}, arity: 1},
    :list => %{type: :Any, arity: :variadic}
  }

  def types, do: @types
  def type_bindings, do: @type_bindings

  @doc "Mapa de definições primitivas de execução `{módulo, nome} => função`."
  def runtime_defs do
    names = [
      :+,
      :-,
      :*,
      :/,
      :**,
      :==,
      :!=,
      :<,
      :>,
      :<=,
      :>=,
      :not,
      :list
    ]

    Enum.reduce(names, %{}, fn name, acc ->
      case get_binding(name) do
        {:ok, fun} ->
          acc
          |> Map.put({nil, name}, fun)
          |> Map.put({:prelude, name}, fun)

        :error ->
          acc
      end
    end)
  end

  @doc "Retorna a função de runtime para uma operação do prelude."
  def get_binding(:+),
    do: {:ok, fn args -> Enum.reduce(args, 0, fn x, acc -> acc + unwrap(x) end) end}

  def get_binding(:-),
    do:
      {:ok,
       fn
         [x] -> -unwrap(x)
         [x | rest] -> Enum.reduce(rest, unwrap(x), fn y, acc -> acc - unwrap(y) end)
       end}

  def get_binding(:*),
    do: {:ok, fn args -> Enum.reduce(args, 1, fn x, acc -> acc * unwrap(x) end) end}

  def get_binding(:/),
    do:
      {:ok,
       fn
         [x] ->
           val = unwrap(x)
           if is_integer(val) and val == 1, do: 1, else: 1 / val

         [x | rest] ->
           Enum.reduce(rest, unwrap(x), fn y, acc ->
             item = unwrap(y)

             if is_integer(acc) and is_integer(item) and rem(acc, item) == 0 do
               div(acc, item)
             else
               acc / item
             end
           end)
       end}

  def get_binding(:**),
    do:
      {:ok,
       fn [base, exp] ->
         b = unwrap(base)
         e = unwrap(exp)

         if is_integer(b) and is_integer(e) and e >= 0 do
           Integer.pow(b, e)
         else
           :math.pow(b, e)
         end
       end}

  def get_binding(:==),
    do: {:ok, fn [a, b] -> if unwrap(a) == unwrap(b), do: true, else: false end}

  def get_binding(:!=),
    do: {:ok, fn [a, b] -> if unwrap(a) != unwrap(b), do: true, else: false end}

  def get_binding(:<),
    do: {:ok, fn [a, b] -> if unwrap(a) < unwrap(b), do: true, else: false end}

  def get_binding(:>),
    do: {:ok, fn [a, b] -> if unwrap(a) > unwrap(b), do: true, else: false end}

  def get_binding(:<=),
    do: {:ok, fn [a, b] -> if unwrap(a) <= unwrap(b), do: true, else: false end}

  def get_binding(:>=),
    do: {:ok, fn [a, b] -> if unwrap(a) >= unwrap(b), do: true, else: false end}

  def get_binding(:list), do: {:ok, fn args -> args end}

  def get_binding(:not),
    do: {:ok, fn [a] -> if truthy?(unwrap(a)), do: false, else: true end}

  def get_binding(_other), do: :error

  @doc "Inicializa um Env com tipos e definições do prelude."
  def init(env \\ Env.new()) do
    # Registra tipos do prelude no nível raiz e sob :prelude
    env_with_types =
      Enum.reduce(@types, env, fn {name, type}, current_env ->
        current_env
        |> Env.put_type(name, type)
        |> Map.update!(:types, &Map.put(&1, {:prelude, name}, type))
      end)

    # Registra definições estáticas do prelude no nível raiz e sob :prelude
    env_with_defs =
      Enum.reduce(@type_bindings, env_with_types, fn {name, type_meta}, current_env ->
        current_env
        |> Env.put_def(name, type_meta)
        |> Map.update!(:defs, &Map.put(&1, {:prelude, name}, type_meta))
      end)

    if env_with_defs.runtime_env do
      env_with_defs
    else
      %{env_with_defs | runtime_env: Core.RuntimeEnv.from_compile_env(env_with_defs)}
    end
  end

  def unwrap(%Literal{value: val}), do: val
  def unwrap(val), do: val

  def truthy?(%Literal{type: :Key, value: val}), do: truthy?(val)

  def truthy?(val) do
    val not in [false, nil]
  end
end
