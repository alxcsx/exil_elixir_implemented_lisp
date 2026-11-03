defmodule Midfield.MacroExpander do
  @moduledoc """
  Fase de macro: reconhece `def-macro`, `quote`, `unquote` e
  `unquote-splicing`, expandindo chamadas de macros procedurais.
  """
  alias Core.Env
  alias Core.AST
  alias Core.AST.{List, Identifier, Literal, Tuple}

  @max_expansion_depth 128

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
            %Identifier{name: :"def-macro"},
            %Identifier{name: macro_name},
            %Tuple{} = params_tuple | body
          ],
          meta: meta
        } = node,
        env,
        _depth
      ) do
    if body == [] do
      raise "macro #{macro_name} deve ter pelo menos um corpo na linha #{meta[:line]}"
    end

    {fixed, rest} = parse_macro_params!(params_tuple, meta)
    macro_node = %{name: macro_name, args: fixed, rest: rest, body: body, meta: node.meta}

    {nil, Env.put_macro(env, macro_name, macro_node)}
  end

  def expand(%List{elements: [%Identifier{name: :"def-macro"} | _]} = node, _env, _depth) do
    raise "sintaxe inválida para def-macro na linha #{node.meta[:line]}"
  end

  def expand(%List{elements: [%Identifier{name: :quote}, template]}, env, _depth) do
    compiled = compile_quote(template, env)
    expand(compiled, env, 0)
  end

  def expand(%List{elements: [%Identifier{name: :quote} | args], meta: meta}, _env, _depth) do
    raise "quote espera exatamente 1 argumento na linha #{line_of(meta)}, recebeu #{length(args)}"
  end

  def expand(%List{elements: [%Identifier{name: :unquote} | _]} = node, _env, _depth),
    do:
      raise("unquote só pode ser usado dentro de quote na linha #{line_of(node.meta)}")

  def expand(%List{elements: [%Identifier{name: :"unquote-splicing"} | _]} = node, _env, _depth),
    do:
      raise(
        "unquote-splicing só pode ser usado dentro de quote na linha #{line_of(node.meta)}"
      )

  def expand(%List{elements: [%Identifier{name: :import}, %Identifier{name: mod}]}, env, _depth) do
    new_env = Env.import_module(env, mod)
    {nil, new_env}
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
    new_env = Env.alias_module(env, alias_name, mod)
    {nil, new_env}
  end

  def expand(%List{elements: [%Identifier{name: fn_name} = head | args]} = node, env, depth) do
    if depth > @max_expansion_depth do
      raise "limite de expansão de macro excedido na linha #{node.meta[:line]} (possível recursão infinita)"
    end

    if Env.has_macro?(env, fn_name) do
      apply_macro(fn_name, args, env) |> expand(env, depth + 1)
    else
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
        Map.put(bindings, macro_node.rest.name, %List{
          elements: Enum.drop(call_args, fixed_count)
        })
      else
        bindings
      end

    child_env =
      Core.RuntimeEnv.from_compile_env(parent_env)
      |> Core.RuntimeEnv.put_vars(bindings)

    compiled_body = Enum.map(macro_node.body, &expand_macro_body(&1, parent_env))

    eval_fun =
      case Keyword.get(parent_env.opts, :macro_engine) do
        fun when is_function(fun, 2) ->
          fun

        :interpreter ->
          &Backend.Interpreter.eval_sequence/2

        mod when is_atom(mod) and not is_nil(mod) ->
          if Code.ensure_loaded?(mod) and function_exported?(mod, :eval_sequence, 2) do
            &mod.eval_sequence/2
          else
            raise "macro_engine #{inspect(mod)} não exporta eval_sequence/2"
          end

        nil ->
          raise "nenhum macro_engine configurado em Env.opts para executar a macro #{macro_name}"

        other ->
          raise "macro_engine inválido: #{inspect(other)}"
      end

    {result, _} = eval_fun.(compiled_body, child_env)
    Core.AST.to_ast(result)
  end

  # -- Expansão de `quote` e chamadas variádicas dentro do corpo da macro

  defp expand_macro_body(%List{elements: [%Identifier{name: :quote}, template]}, env) do
    compile_quote(template, env)
  end

  defp expand_macro_body(%List{elements: [%Identifier{name: :quote} | args]}, _env) do
    raise "quote espera exatamente 1 argumento, recebeu #{length(args)}"
  end

  defp expand_macro_body(
         %List{elements: [%Identifier{name: fn_name} = head | args], meta: meta} = node,
         env
       ) do
    expanded_args = Enum.map(args, &expand_macro_body(&1, env))

    packed_args =
      case Env.get_var(env, fn_name) do
        %{arity: {:at_least, fixed_count}} when length(expanded_args) >= fixed_count ->
          {fixed, rest} = Enum.split(expanded_args, fixed_count)
          fixed ++ [make_list(rest, meta)]

        _ ->
          expanded_args
      end

    %List{node | elements: [head | packed_args]}
  end

  defp expand_macro_body(%List{elements: elements} = node, env) do
    %List{node | elements: Enum.map(elements, &expand_macro_body(&1, env))}
  end

  defp expand_macro_body(%Tuple{elements: elements} = node, env) do
    %Tuple{node | elements: Enum.map(elements, &expand_macro_body(&1, env))}
  end

  defp expand_macro_body(%AST.Map{pairs: pairs} = node, env) do
    %AST.Map{
      node
      | pairs: Enum.map(pairs, fn {k, v} -> {expand_macro_body(k, env), expand_macro_body(v, env)} end)
    }
  end

  defp expand_macro_body(other, _env), do: other

  defp compile_quote(%List{elements: [%Identifier{name: :unquote}, expr]}, env) do
    macro_ffi(:to_ast, [expand_macro_body(expr, env)])
  end

  defp compile_quote(%List{elements: [%Identifier{name: :unquote} | _], meta: meta}, _env) do
    raise "unquote deve receber exatamente um parâmetro na linha #{line_of(meta)}"
  end

  defp compile_quote(%List{elements: [%Identifier{name: :"unquote-splicing"} | _], meta: meta}, _env) do
    raise "unquote-splicing inválido na linha #{line_of(meta)}"
  end

  defp compile_quote(%List{elements: elements, meta: meta}, env) do
    chunks = Enum.map(elements, &compile_quote_element(&1, env))
    macro_ffi(:build_list, [make_list(chunks), make_meta_node(meta)])
  end

  defp compile_quote(%Tuple{elements: elements, meta: meta}, env) do
    chunks = Enum.map(elements, &compile_quote_element(&1, env))
    macro_ffi(:build_tuple, [make_list(chunks), make_meta_node(meta)])
  end

  defp compile_quote(%AST.Map{pairs: pairs, meta: meta}, env) do
    compiled_pairs =
      Enum.map(pairs, fn {k, v} ->
        make_list([compile_quote(k, env), compile_quote(v, env)])
      end)

    macro_ffi(:build_map, [make_list(compiled_pairs), make_meta_node(meta)])
  end

  defp compile_quote(%Identifier{name: name}, _env) do
    macro_ffi(:identifier, [%Literal{type: :Key, value: name}])
  end

  defp compile_quote(%Literal{type: :Int, value: val}, _env) do
    macro_ffi(:int, [%Literal{type: :Int, value: val}])
  end

  defp compile_quote(%Literal{type: :Float, value: val}, _env) do
    macro_ffi(:float, [%Literal{type: :Float, value: val}])
  end

  defp compile_quote(%Literal{type: :Str, value: val}, _env) do
    macro_ffi(:str, [%Literal{type: :Str, value: val}])
  end

  defp compile_quote(%Literal{type: :Key, value: val}, _env) do
    macro_ffi(:key, [%Literal{type: :Key, value: val}])
  end

  defp compile_quote(%Literal{type: :Type, value: val}, _env) do
    macro_ffi(:type_literal, [%Literal{type: :Key, value: val}])
  end

  defp compile_quote(leaf, _env) do
    macro_ffi(:to_ast, [leaf])
  end

  defp compile_quote_element(
         %List{elements: [%Identifier{name: :"unquote-splicing"}, expr], meta: meta},
         env
       ) do
    macro_ffi(:splice_items, [expand_macro_body(expr, env), make_meta_node(meta)])
  end

  defp compile_quote_element(
         %List{elements: [%Identifier{name: :"unquote-splicing"} | _], meta: meta},
         _env
       ) do
    raise "unquote-splicing inválido na linha #{line_of(meta)}"
  end

  defp compile_quote_element(elem, env) do
    make_list([compile_quote(elem, env)])
  end

  defp make_meta_node(meta) when is_map(meta) do
    pairs =
      meta
      |> Enum.filter(fn {k, _v} -> is_atom(k) end)
      |> Enum.map(fn {k, v} ->
        val_node =
          cond do
            is_integer(v) -> %Literal{type: :Int, value: v}
            is_float(v) -> %Literal{type: :Float, value: v}
            is_atom(v) -> %Literal{type: :Key, value: v}
            true -> %Literal{type: :Str, value: to_string(v)}
          end

        {%Literal{type: :Key, value: k}, val_node}
      end)

    %AST.Map{pairs: pairs, meta: %{}}
  end

  defp make_meta_node(_), do: %AST.Map{pairs: [], meta: %{}}

  defp macro_ffi(fun, args) do
    ffi = %List{
      elements: [
        %Identifier{name: :_ffi},
        %Literal{type: :Key, value: Core.AST},
        %Literal{type: :Key, value: fun},
        %Literal{type: :Int, value: length(args)}
      ]
    }

    %List{elements: [ffi | args]}
  end

  defp make_list(elements, meta \\ %{}) do
    %List{elements: [%Identifier{name: :list} | elements], meta: meta}
  end

  defp parse_macro_params!(%Tuple{elements: parameters}, meta) do
    {fixed, tail} = Enum.split_while(parameters, &identifier?/1)

    case tail do
      [] ->
        check_unique_params!(fixed, meta)
        {fixed, nil}

      [%Identifier{name: :|}, %Identifier{name: rest_name} = rest] when rest_name != :| ->
        check_unique_params!(fixed ++ [rest], meta)
        {fixed, rest}

      _ ->
        raise_at(
          "parâmetros devem ser identificadores, com | apenas antes do parâmetro final",
          meta
        )
    end
  end

  defp check_unique_params!(identifiers, meta) do
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

  defp raise_at(message, meta) do
    case line_of(meta) do
      "?" -> raise message
      line -> raise "#{message} na linha #{line}"
    end
  end

  defp line_of(meta) when is_map(meta), do: Map.get(meta, :line, "?")
  defp line_of(_), do: "?"
end
