defmodule Core.Type do
  @moduledoc """
  Regras puras da álgebra do sistema de tipos, verificação de subtipagem
  e reflexão de tipos em tempo de execução.

  Totalmente desacoplado de fases do compilador (`Midfield` e `Parser`).
  """

  @primitive_types [:Any, :Int, :Float, :Symbol, :Str, :List, :Tuple, :Map]

  @doc "Retorna a lista de tipos primitivos da linguagem."
  def primitive_types, do: @primitive_types

  @doc """
  Verifica se o tipo `actual` é subtipo de `expected`.
  """
  def subtype?(:Any, _expected), do: true
  def subtype?(_actual, :Any), do: true

  def subtype?({:Union, alternatives}, expected) do
    Enum.all?(alternatives, &subtype?(&1, expected))
  end

  def subtype?(actual, {:Union, alternatives}) do
    Enum.any?(alternatives, &subtype?(actual, &1))
  end

  def subtype?(actual, {:Intersection, requirements}) do
    Enum.all?(requirements, &subtype?(actual, &1))
  end

  def subtype?({:Intersection, requirements}, expected) do
    Enum.any?(requirements, &subtype?(&1, expected)) or
      case merge_map_requirements(requirements) do
        {:ok, merged} -> subtype?({:Map, merged}, expected)
        :error -> false
      end
  end

  def subtype?({:Symbol, _value}, :Symbol), do: true

  def subtype?({:Tuple, actual}, {:Tuple, expected}) do
    length(actual) == length(expected) and
      Enum.zip(actual, expected)
      |> Enum.all?(fn {element, required} -> subtype?(element, required) end)
  end

  def subtype?({:Tuple, _elements}, :Tuple), do: true

  def subtype?({:Map, actual}, {:Map, expected}) do
    Enum.all?(expected, fn {key, required_type} ->
      case Map.fetch(actual, key) do
        {:ok, actual_type} -> subtype?(actual_type, required_type)
        :error -> false
      end
    end)
  end

  def subtype?({:Map, _fields}, :Map), do: true

  def subtype?({:List, actual}, {:List, expected}),
    do: subtype?(actual, expected)

  def subtype?({:List, _element}, :List), do: true

  def subtype?({:Fn, actual_args, actual_result}, {:Fn, expected_args, expected_result}) do
    length(actual_args) == length(expected_args) and
      Enum.zip(actual_args, expected_args)
      |> Enum.all?(fn {actual_arg, expected_arg} -> subtype?(expected_arg, actual_arg) end) and
      subtype?(actual_result, expected_result)
  end

  def subtype?({:Fn, _arguments, _result}, :Fn), do: true

  def subtype?(type, type), do: true
  def subtype?(_actual, _expected), do: false

  @doc "Mescla múltiplos requisitos de mapa em interseção."
  def merge_map_requirements(types) do
    Enum.reduce_while(types, {:ok, %{}}, fn
      {:Map, fields}, {:ok, merged} ->
        combined =
          Map.merge(merged, fields, fn _key, left, right -> {:Intersection, [left, right]} end)

        {:cont, {:ok, combined}}

      _, {:ok, _} ->
        {:halt, :error}
    end)
  end

  @doc """
  Substitui variáveis de tipo em uma estrutura de tipo.
  """
  def substitute({:type_var, name}, substitutions),
    do: Map.get(substitutions, name, :Any)

  def substitute({:List, element}, substitutions),
    do: {:List, substitute(element, substitutions)}

  def substitute({:Tuple, elements}, substitutions),
    do: {:Tuple, Enum.map(elements, &substitute(&1, substitutions))}

  def substitute({:Map, fields}, substitutions) do
    {:Map, Map.new(fields, fn {key, type} -> {key, substitute(type, substitutions)} end)}
  end

  def substitute({:Fn, arguments, result}, substitutions) do
    {:Fn, Enum.map(arguments, &substitute(&1, substitutions)), substitute(result, substitutions)}
  end

  def substitute({:Union, types}, substitutions),
    do: {:Union, Enum.map(types, &substitute(&1, substitutions))}

  def substitute({:Intersection, types}, substitutions),
    do: {:Intersection, Enum.map(types, &substitute(&1, substitutions))}

  def substitute(type, _substitutions), do: type

  @doc """
  Inspeciona um valor Elixir em tempo de execução e devolve seu tipo canônico.
  """
  def of_value(val) when is_integer(val), do: :Int
  def of_value(val) when is_float(val), do: :Float
  def of_value(val) when is_binary(val), do: :Str
  def of_value(val) when is_atom(val), do: {:Symbol, val}

  def of_value(val) when is_tuple(val) do
    types = val |> :erlang.tuple_to_list() |> Enum.map(&of_value/1)
    {:Tuple, types}
  end

  def of_value(val) when is_list(val) do
    elem_types =
      val
      |> Enum.map(&of_value/1)
      |> Enum.uniq()

    case elem_types do
      [] -> {:List, :Any}
      [single] -> {:List, single}
      multiple -> {:List, {:Union, multiple}}
    end
  end

  def of_value(%_{} = struct) do
    fields =
      struct
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {k, of_value(v)} end)

    {:Map, fields}
  end

  def of_value(val) when is_map(val) do
    fields = Map.new(val, fn {k, v} -> {k, of_value(v)} end)
    {:Map, fields}
  end

  def of_value(val) when is_function(val) do
    {:arity, arity} = :erlang.fun_info(val, :arity)
    {:Fn, Elixir.List.duplicate(:Any, arity), :Any}
  end

  def of_value(_other), do: :Any
end
