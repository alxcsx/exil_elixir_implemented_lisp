defmodule Parser.Desugar do
  @moduledoc """
  Simplifica construções sintáticas logo após o parser:
  - Normaliza parâmetros de `defmacro` em lista `(x y)` para tupla `[x y]`.
  - Valida parâmetros de `fn` e `defmacro` (identificadores únicos, `|` apenas antes do último)
    e transforma `[a b | rest]` em `[a b rest]` marcando `variadic: 2` no `meta` da tupla.
  - Valida e desdobra `let` com múltiplos vínculos `[a 1 b 2]` em `let`s aninhados de um único par.
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

  # Quote é dado bruto: não desdobra o interior (tratado pelo MacroExpander).
  def desugar!(%List{elements: [%Identifier{name: :quote}, _]} = node), do: node

  # Normaliza (defmacro nome (a b) ...) -> (defmacro nome [a b] ...)
  def desugar!(
        %List{
          elements: [
            %Identifier{name: :defmacro} = head,
            %Identifier{} = name,
            %List{elements: params, meta: pmeta} | body
          ]
        } = node
      ) do
    desugar!(%List{node | elements: [head, name, %Tuple{elements: params, meta: pmeta} | body]})
  end

  # Valida e simplifica parâmetros de defmacro
  def desugar!(
        %List{
          elements: [
            %Identifier{name: :defmacro} = head,
            %Identifier{} = name,
            %Tuple{} = params | body
          ],
          meta: meta
        } = node
      ) do
    %List{
      node
      | elements: [head, name, desugar_params!(params, meta) | Enum.map(body, &desugar!/1)]
    }
  end

  # Valida e simplifica parâmetros de fn
  def desugar!(
        %List{
          elements: [%Identifier{name: :fn} = head, %Tuple{} = params | body],
          meta: meta
        } = node
      ) do
    %List{node | elements: [head, desugar_params!(params, meta) | Enum.map(body, &desugar!/1)]}
  end

  # Valida e desdobra (let [a 1 b 2] ...) em (let [a 1] (let [b 2] ...))
  def desugar!(
        %List{
          elements: [%Identifier{name: :let} = head, %Tuple{elements: bindings} = tup | body],
          meta: meta
        } = node
      ) do
    pairs = validate_let_bindings!(bindings, meta)
    desugared_body = Enum.map(body, &desugar!/1)

    case pairs do
      [] ->
        %List{node | elements: [head, tup | desugared_body]}

      _ ->
        Elixir.List.foldr(pairs, nil, fn {k, v}, inner ->
          let_body = if inner, do: [inner], else: desugared_body
          %List{elements: [head, %Tuple{tup | elements: [k, desugar!(v)]} | let_body], meta: meta}
        end)
    end
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

  defp desugar_params!(%Tuple{elements: parameters, meta: tmeta} = tuple, meta) do
    {fixed, tail} = Enum.split_while(parameters, &identifier?/1)

    case tail do
      [] ->
        check_unique!(fixed, meta)
        %Tuple{tuple | elements: fixed}

      [%Identifier{name: :|}, %Identifier{name: rest_name} = rest] when rest_name != :| ->
        all = fixed ++ [rest]
        check_unique!(all, meta)
        %Tuple{tuple | elements: all, meta: Map.put(tmeta, :variadic, length(fixed))}

      _ ->
        raise_at(
          "parâmetros devem ser identificadores, com | apenas antes do parâmetro final",
          meta
        )
    end
  end

  defp validate_let_bindings!(bindings, meta) do
    if rem(length(bindings), 2) != 0 do
      raise_at("let deve conter pares de identificador e valor", meta)
    end

    pairs =
      bindings
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [%Identifier{} = k, v] -> {k, v}
        _ -> raise_at("let deve conter pares de identificador e valor", meta)
      end)

    check_unique!(Enum.map(pairs, &elem(&1, 0)), meta)
    pairs
  end

  defp check_unique!(identifiers, meta) do
    names = Enum.map(identifiers, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [dup | _] ->
        dup_node = Enum.find(identifiers, &(&1.name == dup))
        raise_at("declaração duplicada de #{dup}", dup_node.meta || meta)
    end
  end

  defp identifier?(%Identifier{name: name}) when name != :|, do: true
  defp identifier?(_), do: false

  defp raise_at(message, meta) when is_map(meta) do
    case Map.get(meta, :line) do
      nil -> raise message
      line -> raise "#{message} na linha #{line}"
    end
  end

  defp raise_at(message, _meta), do: raise(message)
end
