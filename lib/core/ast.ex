defmodule Core.AST do
  @moduledoc """
  Representação em memória de cada elemento da árvore de sintaxe abstrata.
  """

  # Top Level Module
  defmodule Module, do: defstruct([:name, :body, meta: %{}])

  # Literals & Estruturas
  defmodule Literal, do: defstruct([:value, :type, meta: %{}])
  defmodule Identifier, do: defstruct([:name, meta: %{}])
  defmodule List, do: defstruct([:elements, meta: %{}])
  defmodule Map, do: defstruct([:pairs, meta: %{}])
  defmodule Tuple, do: defstruct([:elements, meta: %{}])

  # -- Construtores de nós AST

  def identifier(name, meta \\ %{}), do: %Identifier{name: to_atom_name(name), meta: meta}
  def literal(value, type, meta \\ %{}), do: %Literal{value: value, type: type, meta: meta}
  def int(val, meta \\ %{}), do: %Literal{value: val, type: :Int, meta: meta}
  def float(val, meta \\ %{}), do: %Literal{value: val, type: :Float, meta: meta}
  def str(val, meta \\ %{}), do: %Literal{value: val, type: :Str, meta: meta}
  def key(val, meta \\ %{}), do: %Literal{value: val, type: :Key, meta: meta}
  def type_literal(val, meta \\ %{}), do: %Literal{value: val, type: :Type, meta: meta}

  def list(elements, meta \\ %{}) do
    %List{elements: Enum.map(to_elements(elements), &to_ast_node/1), meta: meta}
  end

  def tuple(elements, meta \\ %{}) do
    %Tuple{elements: Enum.map(to_elements(elements), &to_ast_node/1), meta: meta}
  end

  def map(pairs, meta \\ %{}) do
    pairs_list =
      cond do
        is_map(pairs) and not is_struct(pairs) ->
          Enum.map(pairs, fn {k, v} -> {to_ast_node(k), to_ast_node(v)} end)

        is_list(pairs) ->
          Enum.map(pairs, fn
            {k, v} -> {to_ast_node(k), to_ast_node(v)}
            [k, v] -> {to_ast_node(k), to_ast_node(v)}
          end)

        true ->
          []
      end

    %Map{pairs: pairs_list, meta: meta}
  end

  def call(head, args, meta \\ %{}) do
    args_list =
      case args do
        [single] when is_list(single) or is_tuple(single) or is_struct(single, List) or is_struct(single, Tuple) ->
          to_elements(single)

        other ->
          to_elements(other)
      end

    list([head | args_list], meta)
  end

  def module(name, body, meta \\ %{}) do
    %Module{name: to_atom_name(name), body: Enum.map(body, &to_ast_node/1), meta: meta}
  end

  defp to_elements(%List{elements: elements}), do: elements
  defp to_elements(%Tuple{elements: elements}), do: elements
  defp to_elements(elements) when is_tuple(elements), do: :erlang.tuple_to_list(elements)
  defp to_elements(elements) when is_list(elements), do: elements
  defp to_elements(elements), do: [elements]

  # -- Predicados de tipo de nó

  def identifier?(%Identifier{}), do: true
  def identifier?(_), do: false

  def literal?(%Literal{}), do: true
  def literal?(_), do: false

  def list?(%List{}), do: true
  def list?(_), do: false

  def tuple?(%Tuple{}), do: true
  def tuple?(_), do: false

  def map?(%Map{}), do: true
  def map?(_), do: false

  def module?(%Module{}), do: true
  def module?(_), do: false

  # -- Acessores de propriedades

  def node_name(%Identifier{name: name}), do: name
  def node_name(%Module{name: name}), do: name
  def node_name(_), do: nil

  def node_value(%Literal{value: value}), do: value
  def node_value(_), do: nil

  def node_type(%Literal{type: type}), do: type
  def node_type(_), do: nil

  def node_elements(%List{elements: elements}), do: elements
  def node_elements(%Tuple{elements: elements}), do: elements
  def node_elements(_), do: []

  def node_pairs(%Map{pairs: pairs}), do: pairs
  def node_pairs(_), do: []

  def node_meta(%{meta: meta}), do: meta
  def node_meta(_), do: %{}

  # -- Normalização / Conversão de tipos primitivos em nós AST

  def to_ast_node(%_struct{} = node), do: node
  def to_ast_node(val) when is_integer(val), do: int(val)
  def to_ast_node(val) when is_float(val), do: float(val)
  def to_ast_node(val) when is_binary(val), do: str(val)
  def to_ast_node(val) when is_atom(val), do: identifier(val)
  def to_ast_node(list) when is_list(list), do: list(list)
  def to_ast_node(tuple) when is_tuple(tuple), do: tuple(tuple)
  def to_ast_node(%{} = map), do: map(map)
  def to_ast_node(other), do: other

  # -- Construtores auxiliares para avaliação de macros e quote

  @doc false
  def unwrap_leaf({:quoted_leaf, leaf}), do: leaf

  @doc false
  def build_list(chunks, meta), do: %List{elements: :lists.append(chunks), meta: meta}

  @doc false
  def build_tuple(chunks, meta), do: %Tuple{elements: :lists.append(chunks), meta: meta}

  @doc false
  def build_map(pairs, meta) do
    %Map{pairs: Enum.map(pairs, fn [k, v] -> {k, v} end), meta: meta}
  end

  @doc false
  def splice_items(%Tuple{elements: items}, _meta), do: items
  def splice_items(%List{elements: items}, _meta), do: items
  def splice_items(list, _meta) when is_list(list), do: Enum.map(list, &to_ast/1)

  def splice_items(tuple, _meta) when is_tuple(tuple),
    do: tuple |> :erlang.tuple_to_list() |> Enum.map(&to_ast/1)

  def splice_items(_other, meta) do
    line = if is_map(meta), do: Elixir.Map.get(meta, :line, "?"), else: "?"
    raise "unquote-splicing espera lista ou tupla na linha #{line}"
  end

  @doc "Converte valores avaliados de volta em nós AST."
  def to_ast(%_struct{} = ast) when is_struct(ast), do: ast
  def to_ast(val) when is_integer(val), do: %Literal{type: :Int, value: val}
  def to_ast(val) when is_float(val), do: %Literal{type: :Float, value: val}
  def to_ast(val) when is_binary(val), do: %Literal{type: :Str, value: val}
  def to_ast(val) when is_atom(val), do: %Literal{type: :Key, value: val}
  def to_ast(list) when is_list(list), do: %List{elements: Enum.map(list, &to_ast/1)}

  def to_ast(tuple) when is_tuple(tuple),
    do: %Tuple{elements: tuple |> :erlang.tuple_to_list() |> Enum.map(&to_ast/1)}

  def to_ast(%{} = map),
    do: %Map{pairs: Enum.map(map, fn {k, v} -> {to_ast(k), to_ast(v)} end)}

  def to_ast(other), do: other

  defp to_atom_name(name) when is_atom(name), do: name
  defp to_atom_name(name) when is_binary(name), do: String.to_atom(name)
end
