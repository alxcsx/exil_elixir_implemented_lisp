defmodule Midfield.Desugar do
  @moduledoc """
  Normaliza a sintaxe de superfície após a fase de macro expansão:
  - Transforma parâmetros variádicos `[a b | rest]` na tupla canônica `[a b rest]`
    com `variadic: length(fixed)` nos metadados.
  """

  alias Core.AST
  alias Core.AST.{Identifier, List, Tuple}

  def run(forms) do
    {:ok, desugar!(forms)}
  rescue
    e in RuntimeError -> {:error, e.message}
  end

  def desugar!(%AST.Module{body: forms} = mod) do
    %AST.Module{mod | body: Enum.map(forms, &desugar!/1)}
  end

  def desugar!(forms) when is_list(forms) do
    Enum.map(forms, &desugar!/1)
  end

  # Normaliza parâmetros de fn
  def desugar!(
        %List{
          elements: [%Identifier{name: :fn} = head, %Tuple{} = params | body],
          meta: meta
        } = node
      ) do
    %List{node | elements: [head, desugar_params(params, meta) | Enum.map(body, &desugar!/1)]}
  end

  def desugar!(%List{elements: elements} = node) do
    %List{node | elements: Enum.map(elements, &desugar!/1)}
  end

  def desugar!(%Tuple{elements: elements} = node) do
    %Tuple{node | elements: Enum.map(elements, &desugar!/1)}
  end

  def desugar!(%AST.Map{pairs: pairs} = node) do
    %AST.Map{node | pairs: Enum.map(pairs, fn {k, v} -> {desugar!(k), desugar!(v)} end)}
  end

  def desugar!(other), do: other

  defp desugar_params(%Tuple{elements: parameters, meta: tmeta} = tuple, meta) do
    {fixed, tail} = Enum.split_while(parameters, &not_pipe?/1)

    case tail do
      [] ->
        tuple

      [%Identifier{name: :|}, rest] ->
        %Tuple{tuple | elements: fixed ++ [rest], meta: Map.put(tmeta, :variadic, length(fixed))}

      _ ->
        raise_at("parâmetros variádicos devem ter | apenas antes do parâmetro final", meta)
    end
  end

  defp not_pipe?(%Identifier{name: :|}), do: false
  defp not_pipe?(_), do: true

  defp raise_at(message, meta) when is_map(meta) do
    case Map.get(meta, :line) do
      nil -> raise message
      line -> raise "#{message} na linha #{line}"
    end
  end

  defp raise_at(message, _meta), do: raise(message)
end
