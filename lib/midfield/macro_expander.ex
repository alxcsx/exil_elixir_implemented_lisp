defmodule Midfield.MacroExpander do
  @moduledoc """
  Fase de macro: reconhece `defmacro`, `quote`, `unquote` e
  `unquote-splicing`, expandindo chamadas de macros procedurais.
  """
  alias Core.Env
  alias Core.AST
  alias Core.AST.{List, Identifier, Literal, Tuple}
  alias Parser.Desugar

  @max_expansion_depth 128

  def run(%AST.Module{body: trees} = root, env) do
    try do
      trees = Desugar.desugar!(trees)
      {expanded_trees, final_env} = expand_list(trees, env)
      {:ok, %AST.Module{root | body: expanded_trees}, final_env}
    rescue
      e in RuntimeError -> {:error, e.message}
    end
  end

  def run(ast, env) do
    try do
      {expanded, final_env} = expand(Desugar.desugar!(ast), env)
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

  def expand(ast, env), do: expand(Desugar.desugar!(ast), env, 0)

  def expand(
        %List{
          elements: [
            %Identifier{name: :defmacro},
            %Identifier{name: macro_name},
            %Tuple{elements: params, meta: tuple_meta} | body
          ]
        } = node,
        env,
        _depth
      ) do
    if body == [] do
      raise "macro #{macro_name} deve ter pelo menos um corpo na linha #{node.meta[:line]}"
    end

    {fixed, rest} =
      case tuple_meta[:variadic] do
        nil -> {params, nil}
        fixed_count -> {Enum.take(params, fixed_count), Elixir.List.last(params)}
      end

    macro_node = %{name: macro_name, args: fixed, rest: rest, body: body, meta: node.meta}

    {nil, Env.put_macro(env, macro_name, macro_node)}
  end

  def expand(%List{elements: [%Identifier{name: :defmacro} | _]} = node, _env, _depth) do
    raise "sintaxe inválida para defmacro na linha #{node.meta[:line]}"
  end

  # Quote fora de macro é dado bruto.
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

  def expand(%List{elements: [%Identifier{name: :import}, mod_elem]}, env, _depth) do
    if mod = module_name(mod_elem) do
      new_env = Env.import_module(env, mod)

      new_runtime_env =
        if new_env.runtime_env do
          %{
            new_env.runtime_env
            | imports: Enum.uniq(new_env.runtime_env.imports ++ [mod]),
              aliases: Map.put_new(new_env.runtime_env.aliases, mod, mod)
          }
        else
          nil
        end

      {nil, %{new_env | runtime_env: new_runtime_env}}
    else
      raise "módulo inválido no import"
    end
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
            mod_elem,
            marker,
            alias_elem
          ]
        },
        env,
        _depth
      ) do
    mod = module_name(mod_elem)

    if mod && alias_marker?(marker) && alias_target?(alias_elem) do
      alias_name = extract_alias_name(alias_elem)

      new_env = Env.alias_module(env, alias_name, mod)

      new_runtime_env =
        if new_env.runtime_env do
          %{
            new_env.runtime_env
            | aliases: Map.put(new_env.runtime_env.aliases, alias_name, mod)
          }
        else
          nil
        end

      {nil, %{new_env | runtime_env: new_runtime_env}}
    else
      raise "sintaxe de import com alias inválida"
    end
  end

  def expand(%List{elements: [%Identifier{name: fn_name} = head | args]} = node, env, depth) do
    if depth > @max_expansion_depth do
      raise "limite de expansão de macro excedido na linha #{node.meta[:line]} (possível recursão infinita)"
    end

    if Env.has_macro?(env, fn_name) do
      apply_macro(fn_name, args, env) |> Desugar.desugar!() |> expand(env, depth + 1)
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
    {result, _} = Backend.Interpreter.eval_sequence(compiled_body, child_env)
    to_ast(result)
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
    macro_ffi(:build_list, [make_list(chunks), meta])
  end

  defp compile_quote(%Tuple{elements: elements, meta: meta}, env) do
    chunks = Enum.map(elements, &compile_quote_element(&1, env))
    macro_ffi(:build_tuple, [make_list(chunks), meta])
  end

  defp compile_quote(%AST.Map{pairs: pairs, meta: meta}, env) do
    compiled_pairs =
      Enum.map(pairs, fn {k, v} ->
        make_list([compile_quote(k, env), compile_quote(v, env)])
      end)

    macro_ffi(:build_map, [make_list(compiled_pairs), meta])
  end

  defp compile_quote(leaf, _env) do
    macro_ffi(:unwrap_leaf, [{:quoted_leaf, leaf}])
  end

  defp compile_quote_element(
         %List{elements: [%Identifier{name: :"unquote-splicing"}, expr], meta: meta},
         env
       ) do
    macro_ffi(:splice_items, [expand_macro_body(expr, env), meta])
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

  defp macro_ffi(fun, args) do
    ffi = %List{
      elements: [
        %Identifier{name: :_ffi},
        %Literal{type: :Key, value: __MODULE__},
        %Literal{type: :Key, value: fun},
        %Literal{type: :Int, value: length(args)}
      ]
    }

    %List{elements: [ffi | args]}
  end

  defp make_list(elements, meta \\ %{}) do
    %List{elements: [%Identifier{name: :list} | elements], meta: meta}
  end

  defp line_of(meta) when is_map(meta), do: Map.get(meta, :line, "?")
  defp line_of(_), do: "?"

  # -- Construtores chamados na avaliação do quote expandido

  @doc false
  def unwrap_leaf({:quoted_leaf, leaf}), do: leaf

  @doc false
  def build_list(chunks, meta), do: %List{elements: :lists.append(chunks), meta: meta}

  @doc false
  def build_tuple(chunks, meta), do: %Tuple{elements: :lists.append(chunks), meta: meta}

  @doc false
  def build_map(pairs, meta) do
    %AST.Map{pairs: Enum.map(pairs, fn [k, v] -> {k, v} end), meta: meta}
  end

  @doc false
  def splice_items(%Tuple{elements: items}, _meta), do: items
  def splice_items(%List{elements: items}, _meta), do: items
  def splice_items(list, _meta) when is_list(list), do: Enum.map(list, &to_ast/1)

  def splice_items(tuple, _meta) when is_tuple(tuple),
    do: tuple |> :erlang.tuple_to_list() |> Enum.map(&to_ast/1)

  def splice_items(_other, meta) do
    raise "unquote-splicing espera lista ou tupla na linha #{line_of(meta)}"
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

  defp module_name(%Identifier{name: name}), do: name
  defp module_name(%Literal{type: :Key, value: val}), do: val
  defp module_name(_), do: nil

  defp alias_marker?(%Identifier{name: name}) when name in [:as, :":>"], do: true
  defp alias_marker?(%Literal{type: :Key, value: val}) when val in [:as, :>], do: true
  defp alias_marker?(_), do: false

  defp alias_target?(%Identifier{name: name}) when name not in [nil, :":>"], do: true
  defp alias_target?(%Literal{type: :Key}), do: true
  defp alias_target?(_), do: false

  defp extract_alias_name(%Identifier{name: name}), do: name
  defp extract_alias_name(%Literal{type: :Key, value: val}), do: val
end
