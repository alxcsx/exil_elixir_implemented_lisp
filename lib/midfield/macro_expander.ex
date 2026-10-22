defmodule Midfield.MacroExpander do
  @moduledoc """
  Fase de macro: reconhece `defmacro`, `quote`, `unquote` e
  `unquote-splicing`.

  Enquanto não há interpretador de tempo de compilação, macros são templates:
  o corpo deve ser um parâmetro ou um único `(quote ...)`. `unquote` e
  `unquote-splicing` só podem referir-se a parâmetros da macro. Isso já cobre
  a expansão sintática sem dar semântica de runtime a essas formas.
  """
  alias Core.Env
  alias Core.Params
  alias Core.AST
  alias Core.AST.{List, Identifier, Literal, Tuple}

  @max_expansion_depth 128

  # shortcut: template-only macros without compile-time evaluator; upgrade when compile-time interpreter is implemented.

  def run(%AST.Module{body: trees} = root, env) do
    try do
      {expanded_trees, final_env} = expand_list(trees, env)
      {:ok, %AST.Module{root | body: expanded_trees}, final_env}
    rescue
      e in RuntimeError -> {:error, e.message}
    end
  end

  def run(ast, env) do
    try do
      {expanded, final_env} = expand(ast, env)
      {:ok, expanded, final_env}
    rescue
      e in RuntimeError -> {:error, e.message}
    end
  end

  def expand_list(nodes, env) do
    {expanded_nodes, final_env} = Enum.map_reduce(nodes, env, &expand/2)
    filtered_nodes = Enum.reject(expanded_nodes, &is_nil/1)
    {filtered_nodes, final_env}
  end

  def expand(ast, env), do: expand(ast, env, 0)

  def expand(
        %List{
          elements: [
            %Identifier{name: :defmacro},
            %Identifier{name: macro_name},
            args_node | body
          ]
        } = node,
        env,
        _depth
      )
      when is_struct(args_node, Tuple) or is_struct(args_node, List) do
    {:ok, %{fixed: args, rest: rest}} = macro_parameters!(args_node.elements, node.meta)

    if length(body) == 0 do
      raise "macro #{macro_name} deve ter pelo menos um corpo na linha #{node.meta[:line]}"
    end

    macro_node = %{name: macro_name, args: args, rest: rest, body: body, meta: node.meta}

    {nil, Env.put_macro(env, macro_name, macro_node)}
  end

  def expand(%List{elements: [%Identifier{name: :defmacro} | _]} = node, _env, _depth) do
    raise "sintaxe inválida para defmacro na linha #{node.meta[:line]}"
  end

  # Quote é dado: não expande macros nem outras formas no corpo.
  def expand(%List{elements: [%Identifier{name: :quote}, _body]} = node, env, _depth),
    do: {node, env}

  def expand(%List{elements: [%Identifier{name: :unquote} | _]} = node, _env, _depth),
    do:
      raise("unquote só pode ser usado dentro de quote em uma macro na linha #{node.meta[:line]}")

  def expand(%List{elements: [%Identifier{name: :"unquote-splicing"} | _]} = node, _env, _depth),
    do:
      raise(
        "unquote-splicing só pode ser usado dentro de quote em uma macro na linha #{node.meta[:line]}"
      )

  def expand(%List{elements: [%Identifier{name: :import}, %Identifier{name: mod}]}, env, _depth) do
    {nil, Env.import_module(env, mod)}
  end

  def expand(
        %List{elements: [%Identifier{name: :import}, %Literal{type: :Str, value: path} | _]},
        _env,
        _depth
      ) do
    raise "import por caminho só no topo do módulo: #{path}"
  end

  def expand(
        %List{
          elements: [
            %Identifier{name: :import},
            %Identifier{name: mod},
            %Identifier{name: :as},
            %Identifier{name: alias_name}
          ]
        },
        env,
        _depth
      ) do
    {nil, Env.alias_module(env, alias_name, mod)}
  end

  def expand(%List{elements: [%Identifier{name: fn_name} = head | args]} = node, env, depth) do
    if depth > @max_expansion_depth do
      raise "limite de expansão de macro excedido na linha #{node.meta[:line]} (possível recursão infinita)"
    end

    if Env.has_macro?(env, fn_name) do
      apply_macro(fn_name, args, env) |> expand(env, depth + 1)
    else
      # não é macro: mantém lista pura, o leitor downstream decide
      {expanded_args, new_env} = expand_list(args, env)
      {%List{node | elements: [head | expanded_args]}, new_env}
    end
  end

  def expand(%List{elements: elements} = node, env, _depth) do
    {expanded_elements, new_env} = expand_list(elements, env)
    {%AST.List{node | elements: expanded_elements}, new_env}
  end

  def expand(%Tuple{elements: elements} = node, env, _depth) do
    {expanded_elements, new_env} = expand_list(elements, env)
    {%Tuple{node | elements: expanded_elements}, new_env}
  end

  def expand(%AST.Map{pairs: pairs} = node, env, _depth) do
    {expanded_pairs, new_env} =
      Enum.map_reduce(pairs, env, fn {key, value}, current_env ->
        {k, env1} = expand(key, current_env, 0)
        {v, env2} = expand(value, env1, 0)
        {{k, v}, env2}
      end)

    {%AST.Map{node | pairs: expanded_pairs}, new_env}
  end

  def expand(ast, env, _depth), do: {ast, env}

  @doc "Expande uma chamada de macro um único nível. Se não for macro, devolve o nó inalterado."
  def macroexpand_1(%List{elements: [%Identifier{name: fn_name} | args]} = node, env) do
    if Env.has_macro?(env, fn_name) do
      apply_macro(fn_name, args, env)
    else
      node
    end
  end

  def macroexpand_1(ast, _env), do: ast

  @doc "Expande chamadas de macro no topo repetidamente até que a forma não seja mais uma macro."
  def macroexpand(%List{elements: [%Identifier{name: fn_name} | args]} = node, env) do
    if Env.has_macro?(env, fn_name) do
      apply_macro(fn_name, args, env) |> macroexpand(env)
    else
      node
    end
  end

  def macroexpand(ast, _env), do: ast

  @doc "Injeta funções de manipulação de macro (:quote) no contexto de execução do interpretador."
  def inject_macro_context(%Core.RuntimeEnv{} = env) do
    quote_handler = fn
      [template], eval_env ->
        {quasiquote(template, eval_env), eval_env}

      args, _eval_env ->
        raise "quote espera exatamente 1 argumento, recebeu #{length(args)}"
    end

    Core.RuntimeEnv.put_macro_handler(env, :quote, quote_handler)
  end

  def inject_macro_context(%Core.Env{} = env) do
    runtime_env =
      (env.runtime_env || Core.RuntimeEnv.from_compile_env(env))
      |> inject_macro_context()

    %{env | runtime_env: runtime_env}
  end

  def apply_macro(macro_name, call_args, parent_env) do
    macro_node = Env.get_macro(parent_env, macro_name)

    if is_nil(macro_node) do
      raise "macro desconhecida: #{macro_name}"
    end

    fixed_count = length(macro_node.args)

    if (is_nil(macro_node.rest) and fixed_count != length(call_args)) or
         (not is_nil(macro_node.rest) and fixed_count > length(call_args)) do
      expectation = if macro_node.rest, do: "at least #{fixed_count}", else: fixed_count
      raise "Macro #{macro_name} expected #{expectation} arguments, got #{length(call_args)}"
    end

    bindings =
      macro_node.args
      |> Enum.map(& &1.name)
      |> Enum.zip(call_args)
      |> Map.new()

    bindings =
      if macro_node.rest do
        Map.put(bindings, macro_node.rest.name, %Tuple{
          elements: Enum.drop(call_args, fixed_count)
        })
      else
        bindings
      end

    child_env =
      Core.RuntimeEnv.from_compile_env(parent_env)
      |> Core.RuntimeEnv.put_vars(bindings)
      |> inject_macro_context()

    {result, _} = Backend.Interpreter.eval_sequence(macro_node.body, child_env)
    to_ast(result)
  end

  # Quasiquotation (gerenciado e de responsabilidade exclusiva da fase de macros)
  def quasiquote(%List{elements: [%Identifier{name: :unquote}, expr]}, env) do
    {val, _} = Backend.Interpreter.eval(expr, env)
    to_ast(val)
  end

  def quasiquote(%List{elements: [%Identifier{name: :unquote} | _], meta: meta}, _env) do
    line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
    raise "unquote deve receber exatamente um parâmetro na linha #{line}"
  end

  def quasiquote(%List{elements: elements} = node, env) do
    expanded =
      Enum.flat_map(elements, fn
        %List{elements: [%Identifier{name: :"unquote-splicing"}, expr], meta: meta} ->
          {val, _} = Backend.Interpreter.eval(expr, env)
          splice_items(val, meta)

        %List{elements: [%Identifier{name: :"unquote-splicing"} | _], meta: meta} ->
          line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
          raise "unquote-splicing inválido na linha #{line}"

        elem ->
          [quasiquote(elem, env)]
      end)

    %List{node | elements: expanded}
  end

  def quasiquote(%Tuple{elements: elements} = node, env) do
    expanded =
      Enum.flat_map(elements, fn
        %List{elements: [%Identifier{name: :"unquote-splicing"}, expr], meta: meta} ->
          {val, _} = Backend.Interpreter.eval(expr, env)
          splice_items(val, meta)

        %List{elements: [%Identifier{name: :"unquote-splicing"} | _], meta: meta} ->
          line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
          raise "unquote-splicing inválido na linha #{line}"

        elem ->
          [quasiquote(elem, env)]
      end)

    %Tuple{node | elements: expanded}
  end

  def quasiquote(%AST.Map{pairs: pairs} = node, env) do
    expanded_pairs =
      Enum.map(pairs, fn {k, v} ->
        {quasiquote(k, env), quasiquote(v, env)}
      end)

    %AST.Map{node | pairs: expanded_pairs}
  end

  def quasiquote(other, _env), do: other

  defp splice_items(%Tuple{elements: items}, _meta), do: items
  defp splice_items(%List{elements: items}, _meta), do: items
  defp splice_items(list, _meta) when is_list(list), do: Enum.map(list, &to_ast/1)

  defp splice_items(tuple, _meta) when is_tuple(tuple),
    do: tuple |> :erlang.tuple_to_list() |> Enum.map(&to_ast/1)

  defp splice_items(_other, meta) do
    line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
    raise "unquote-splicing espera lista ou tupla na linha #{line}"
  end

  # Conversão de valores em AST pós-expansão
  def to_ast(%_struct{} = ast) when is_struct(ast), do: ast
  def to_ast(val) when is_integer(val), do: %Literal{type: :Int, value: val}
  def to_ast(val) when is_float(val), do: %Literal{type: :Float, value: val}
  def to_ast(val) when is_binary(val), do: %Literal{type: :Str, value: val}
  def to_ast(val) when is_atom(val), do: %Literal{type: :Key, value: val}
  def to_ast(list) when is_list(list), do: %List{elements: Enum.map(list, &to_ast/1)}

  def to_ast(tuple) when is_tuple(tuple),
    do: %Tuple{elements: tuple |> :erlang.tuple_to_list() |> Enum.map(&to_ast/1)}

  def to_ast(%{} = map),
    do: %AST.Map{pairs: Enum.map(map, fn {k, v} -> {to_ast(k), to_ast(v)} end)}

  def to_ast(other), do: other

  defp macro_parameters!(parameters, meta) do
    case Params.parse(parameters) do
      {:ok, shape} -> {:ok, shape}
      {:error, message} -> raise "#{message} na linha #{meta[:line]}"
    end
  end
end
