defmodule Midfield.TypeChecker do
  @moduledoc "Valida identificadores, aridades e assinaturas de funções na AST expandida."

  alias Core.AST
  alias Core.AST.{Identifier, List, Tuple}
  alias Core.Env
  alias Parser.Desugar

  @collection_names [:list]
  @special_forms [
    :"<:",
    :def,
    :fn,
    :let,
    :if,
    :spec,
    :"def-type",
    :_ffi,
    :quote,
    :unquote,
    :defmacro,
    :"def-module"
  ]
  @primitive_types [:Any, :Int, :Float, :Symbol, :Str, :List, :Tuple, :Map]
  @type_operators [:U, :u, :&]
  @reserved_names @collection_names ++ @special_forms ++ @primitive_types ++ @type_operators
  @unknown_binding %{type: :Any, arity: :unknown}
  @list_binding %{type: :Any, arity: :variadic}

  def run(%AST.Module{} = module, env) do
    env = add_list_name(env)

    with {:ok, %AST.Module{body: forms} = mod} <- Desugar.run(module),
         {:ok, checked_forms, checked_env} <- check_module_forms(forms, env) do
      {:ok, %AST.Module{mod | body: checked_forms}, checked_env}
    else
      {:error, message} -> {:error, with_file(message, env)}
    end
  end

  def run(ast, env) do
    env = add_list_name(env)

    with {:ok, desugared} <- Desugar.run(ast),
         {:ok, rewritten, checked_env} <- check(desugared, env, :module) do
      {:ok, rewritten, checked_env}
    else
      {:error, message} -> {:error, with_file(message, env)}
    end
  end

  defp with_file(message, %{file: nil}), do: message
  defp with_file(message, %{file: file}), do: "#{file}: #{message}"

  defp add_list_name(env) do
    if Env.has_var?(env, :list), do: env, else: Env.put_var(env, :list, @list_binding)
  end

  defp check_module_forms([], env), do: {:ok, [], env}

  defp check_module_forms([%List{elements: [%Identifier{name: :spec} | _]} = spec | rest], env) do
    with {:ok, name, signature} <- read_spec(spec, env) do
      case rest do
        [
          %List{elements: [%Identifier{name: :def}, %Identifier{name: ^name}, _]} = definition
          | remaining
        ] ->
          with {:ok, rewritten_def, next_env} <-
                 check(definition, Env.put_type(env, {:spec, name}, signature), :module),
               {:ok, checked_rest, final_env} <- check_module_forms(remaining, next_env) do
            {:ok, [rewritten_def | checked_rest], final_env}
          end

        _ ->
          error("spec de #{name} deve preceder imediatamente o def correspondente", spec.meta)
      end
    end
  end

  defp check_module_forms([form | rest], env) do
    with {:ok, rewritten, next_env} <- check(form, env, :module),
         {:ok, checked_rest, final_env} <- check_module_forms(rest, next_env) do
      items = if is_nil(rewritten), do: checked_rest, else: [rewritten | checked_rest]
      {:ok, items, final_env}
    end
  end

  defp check(
         %List{
           elements: [
             %Identifier{name: :"def-type"},
             %List{elements: [%Identifier{} = name, %Tuple{elements: parameters}]},
             type
           ]
         },
         env,
         :module
       ) do
    with :ok <- check_type_name(name, env),
         {:ok, type_env, names} <- bind_type_parameters(parameters, Env.new(env)),
         {:ok, parsed_type} <- parse_type(type, type_env) do
      {:ok, nil, Env.put_type(env, name.name, %{params: names, body: parsed_type})}
    end
  end

  defp check(
         %List{elements: [%Identifier{name: :"def-type"}, %Identifier{} = name, type]},
         env,
         :module
       ) do
    with :ok <- check_type_name(name, env),
         {:ok, parsed_type} <- parse_type(type, env) do
      {:ok, nil, Env.put_type(env, name.name, parsed_type)}
    end
  end

  defp check(
         %List{elements: [%Identifier{name: :def} = head, %Identifier{} = name, value]} = node,
         env,
         :module
       ) do
    cond do
      name.name in @reserved_names ->
        error("identificador reservado #{name.name}", name.meta)

      Map.has_key?(env.defs, {env.current_module, name.name}) ->
        error("declaração duplicada de #{name.name}", name.meta)

      Env.has_type?(env, name.name) ->
        error("nome de variável coincide com tipo: #{name.name}", name.meta)

      true ->
        signature = Env.get_type(env, {:spec, name.name})
        binding = binding_with_signature(binding_for(value, env), signature)

        value_env =
          case value do
            %List{elements: [%Identifier{name: :fn}, %Tuple{} | _]} ->
              Env.new(env) |> Env.put_def(name.name, binding)

            _ ->
              env
          end

        with {:ok, rewritten_value, _} <-
               check_declared_value(value, value_env, signature, name.meta) do
          {:ok, %List{node | elements: [head, name, rewritten_value]},
           Env.put_def(env, name.name, binding)}
        end
    end
  end

  defp check(%List{elements: [%Identifier{name: :def} | _]} = node, _env, _scope),
    do: error("declaração def fora do módulo ou inválida", node.meta)

  defp check(
         %List{elements: [%Identifier{name: :fn} = head, %Tuple{} = params_tuple | body]} = node,
         env,
         _scope
       ) do
    with {:ok, fn_env} <- bind_fn_params(params_tuple, Env.new(env)),
         {:ok, rewritten_body, _} <- check_sequence(body, fn_env, :local) do
      {:ok, %List{node | elements: [head, params_tuple | rewritten_body]}, env}
    end
  end

  defp check(
         %List{elements: [%Identifier{name: :let} = head, %Tuple{elements: []} = tup | body]} =
           node,
         env,
         _scope
       ) do
    with {:ok, rewritten_body, _} <- check_sequence(body, Env.new(env), :local) do
      {:ok, %List{node | elements: [head, tup | rewritten_body]}, env}
    end
  end

  defp check(
         %List{
           elements: [
             %Identifier{name: :let} = head,
             %Tuple{elements: [%Identifier{} = name, value]} = tup | body
           ]
         } = node,
         env,
         _scope
       ) do
    with {:ok, rewritten_val, _} <- check(value, env, :expression),
         {:ok, let_env} <- bind_name(name, Env.new(env), binding_for(rewritten_val, env)),
         {:ok, rewritten_body, _} <- check_sequence(body, let_env, :local) do
      {:ok,
       %List{node | elements: [head, %Tuple{tup | elements: [name, rewritten_val]} | rewritten_body]},
       env}
    end
  end

  defp check(
         %List{elements: [%Identifier{name: :if} = head, cond_expr, then_expr, else_expr]} = node,
         env,
         _scope
       ) do
    with {:ok, [c, t, e], _} <-
           check_sequence([cond_expr, then_expr, else_expr], env, :expression) do
      {:ok, %List{node | elements: [head, c, t, e]}, env}
    end
  end

  defp check(%List{elements: [%Identifier{name: :if} | _], meta: meta}, _env, _scope),
    do: error("if espera exatamente 3 argumentos", meta)

  defp check(
         %List{
           elements: [
             %Identifier{name: :_ffi},
             %AST.Literal{type: :Key},
             %AST.Literal{type: :Key},
             %AST.Literal{type: :Int, value: arity}
           ]
         } = node,
         env,
         _scope
       )
       when arity >= 0,
       do: {:ok, node, env}

  defp check(%List{elements: [%Identifier{name: :_ffi} | _]} = node, _env, _scope),
    do: error("forma _ffi inválida: esperado módulo, função e aridade não negativa", node.meta)

  # O conteúdo de quote é dado, não uma expressão a resolver neste ponto.
  defp check(%List{elements: [%Identifier{name: :quote}, _body]} = node, env, _scope),
    do: {:ok, node, env}

  defp check(
         %List{elements: [%Identifier{name: :"<:"}, type1, type2], meta: meta},
         env,
         _scope
       ) do
    with {:ok, parsed1} <- parse_type(type1, env),
         {:ok, parsed2} <- parse_type(type2, env) do
      result = compatible_types?(parsed1, parsed2)
      {:ok, %AST.Literal{type: :Key, value: result, meta: meta}, env}
    end
  end

  defp check(%List{elements: [%Identifier{name: :"<:"} | _], meta: meta}, _env, _scope) do
    error("<: espera exatamente 2 argumentos", meta)
  end

  defp check(%List{elements: [%Identifier{name: name} | _]} = node, _env, _scope)
       when name in @special_forms,
       do: error("forma especial inválida: #{name}", node.meta)

  defp check(%List{elements: [head | args], meta: meta} = node, env, _scope) do
    with {:ok, [rewritten_head | rewritten_args], _} <-
           check_sequence([head | args], env, :expression),
         :ok <- check_callability(head, env, meta),
         :ok <- check_arity(head, length(args), env, meta),
         :ok <- check_argument_types(head, args, env, meta) do
      packed_args = pack_variadic_args(head, rewritten_args, env, meta)
      {:ok, %List{node | elements: [rewritten_head | packed_args]}, env}
    end
  end

  defp check(%List{elements: []} = node, env, _scope), do: {:ok, node, env}

  defp check(%Tuple{elements: elements} = node, env, _scope) do
    with {:ok, rewritten, _} <- check_sequence(elements, env, :expression) do
      {:ok, %Tuple{node | elements: rewritten}, env}
    end
  end

  defp check(%AST.Map{pairs: pairs} = node, env, _scope) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, rk, _} <- check(key, env, :expression),
           {:ok, rv, _} <- check(value, env, :expression) do
        {:cont, {:ok, [{rk, rv} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, %AST.Map{node | pairs: Enum.reverse(reversed)}, env}
      error -> error
    end
  end

  defp check(%Identifier{name: name, meta: meta} = node, env, _scope) do
    if name in @special_forms or not Env.has_var?(env, name) do
      error("identificador não declarado: #{name}", meta)
    else
      {:ok, node, env}
    end
  end

  defp check(%AST.Literal{} = node, env, _scope), do: {:ok, node, env}

  defp pack_variadic_args(head, args, env, meta) do
    case call_binding(head, env) do
      %{arity: {:at_least, fixed_count}} ->
        {fixed, rest} = Enum.split(args, fixed_count)
        fixed ++ [%List{elements: [%Identifier{name: :list} | rest], meta: meta}]

      _ ->
        args
    end
  end

  defp call_binding(%Identifier{name: name}, env), do: Env.get_var(env, name)
  defp call_binding(expr, env), do: binding_for(expr, env)

  defp check_type_name(%Identifier{name: name, meta: meta}, env) do
    cond do
      name in @reserved_names ->
        error("nome de tipo reservado: #{name}", meta)

      Env.has_var?(env, name) ->
        error("nome de tipo coincide com variável: #{name}", meta)

      Map.has_key?(env.types, {env.current_module, name}) ->
        error("tipo já declarado: #{name}", meta)

      true ->
        :ok
    end
  end

  defp check_type_parameter(%Identifier{name: name, meta: meta} = parameter, env) do
    if name in @type_operators do
      cond do
        Env.has_var?(env, name) -> error("nome de tipo coincide com variável: #{name}", meta)
        Env.has_type?(env, name) -> error("tipo já declarado: #{name}", meta)
        true -> :ok
      end
    else
      check_type_name(parameter, env)
    end
  end

  defp bind_type_parameters(parameters, env) do
    Enum.reduce_while(parameters, {:ok, env, []}, fn
      %Identifier{name: name} = parameter, {:ok, current_env, names} ->
        case check_type_parameter(parameter, current_env) do
          :ok ->
            next_env = Env.put_type(current_env, name, {:type_var, name})
            {:cont, {:ok, next_env, [name | names]}}

          {:error, _} = error ->
            {:halt, error}
        end

      _, {:ok, _, _} ->
        {:halt, {:error, "parâmetro de tipo deve ser um identificador"}}
    end)
    |> case do
      {:ok, type_env, reversed} -> {:ok, type_env, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp check_sequence(forms, env, scope) do
    Enum.reduce_while(forms, {:ok, [], env}, fn form, {:ok, acc, current_env} ->
      case check(form, current_env, scope) do
        {:ok, rewritten, next_env} -> {:cont, {:ok, [rewritten | acc], next_env}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed, final_env} -> {:ok, Enum.reverse(reversed), final_env}
      error -> error
    end
  end

  defp bind_fn_params(%Tuple{elements: params, meta: tuple_meta}, env) do
    case tuple_meta[:variadic] do
      nil ->
        bind_param_types(params, Elixir.List.duplicate(@unknown_binding, length(params)), env)

      fixed_count ->
        bindings =
          Elixir.List.duplicate(@unknown_binding, fixed_count) ++
            [%{type: {:List, :Any}, arity: :unknown}]

        bind_param_types(params, bindings, env)
    end
  end

  defp bind_fn_params(%Tuple{elements: params, meta: tuple_meta}, env, types) do
    if tuple_meta[:variadic] do
      {:error, "spec de função variádica ainda não é suportada"}
    else
      bindings = Enum.map(types, &%{type: &1, arity: arity_for_type(&1)})
      bind_param_types(params, bindings, env)
    end
  end

  defp bind_param_types(params, bindings, env) do
    params
    |> Enum.zip(bindings)
    |> Enum.reduce_while({:ok, env}, fn {%Identifier{} = name, binding}, {:ok, current_env} ->
      case bind_name(name, current_env, binding) do
        {:ok, next_env} -> {:cont, {:ok, next_env}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bind_name(%Identifier{name: name, meta: meta}, env, binding) do
    cond do
      name in @reserved_names -> error("identificador reservado #{name}", meta)
      Map.has_key?(env.vars, name) -> error("declaração duplicada de #{name}", meta)
      Env.has_type?(env, name) -> error("nome de variável coincide com tipo: #{name}", meta)
      true -> {:ok, Env.put_var(env, name, binding)}
    end
  end

  defp binding_for(
         %List{elements: [%Identifier{name: :fn}, %Tuple{elements: params, meta: tmeta} = tup | body]},
         env
       ) do
    result =
      case bind_fn_params(tup, Env.new(env)) do
        {:ok, fn_env} ->
          body |> Elixir.List.last() |> binding_for(fn_env) |> Map.fetch!(:type)

        {:error, _} ->
          :Any
      end

    case tmeta[:variadic] do
      nil ->
        %{
          type: {:Fn, Elixir.List.duplicate(:Any, length(params)), result},
          arity: length(params)
        }

      fixed_count ->
        %{
          type: {:Fn, Elixir.List.duplicate(:Any, fixed_count), result},
          arity: {:at_least, fixed_count}
        }
    end
  end

  defp binding_for(
         %List{elements: [%Identifier{name: :let}, %Tuple{elements: []} | body]},
         env
       ) do
    binding_for(Elixir.List.last(body), Env.new(env))
  end

  defp binding_for(
         %List{
           elements: [
             %Identifier{name: :let},
             %Tuple{elements: [%Identifier{} = name, value]} | body
           ]
         },
         env
       ) do
    case bind_name(name, Env.new(env), binding_for(value, env)) do
      {:ok, let_env} -> binding_for(Elixir.List.last(body), let_env)
      {:error, _} -> @unknown_binding
    end
  end

  defp binding_for(%List{elements: [%Identifier{name: :if}, _condition, yes, no]}, env) do
    yes_binding = binding_for(yes, env)
    no_binding = binding_for(no, env)

    if yes_binding == no_binding, do: yes_binding, else: @unknown_binding
  end

  defp binding_for(%List{elements: [%Identifier{name: :list} | elements]}, env) do
    element_types = Enum.map(elements, fn element -> binding_for(element, env).type end)
    %{type: {:List, list_element_type(element_types)}, arity: :unknown}
  end

  defp binding_for(
         %List{
           elements: [
             %Identifier{name: :_ffi},
             _,
             _,
             %AST.Literal{type: :Int, value: arity}
           ]
         },
         _env
       )
       when arity >= 0,
       do: %{type: {:Fn, Elixir.List.duplicate(:Any, arity), :Any}, arity: arity}

  defp binding_for(%AST.Literal{type: :Key, value: value}, _env),
    do: %{type: {:Symbol, value}, arity: :unknown}

  defp binding_for(%AST.Literal{type: type}, _env) when type in [:Int, :Float, :Str],
    do: %{type: type, arity: :unknown}

  defp binding_for(%Tuple{elements: elements}, env) do
    types = Enum.map(elements, &tuple_element_type(&1, env))
    %{type: {:Tuple, types}, arity: :unknown}
  end

  defp binding_for(%AST.Map{pairs: pairs}, env) do
    pairs
    |> Enum.reduce_while({:ok, %{}}, fn
      {%AST.Literal{type: :Key, value: key}, value}, {:ok, fields} ->
        value_type = value |> binding_for(env) |> Map.fetch!(:type)
        {:cont, {:ok, Map.put(fields, key, value_type)}}

      _, {:ok, _} ->
        {:halt, :unknown}
    end)
    |> case do
      {:ok, fields} -> %{type: {:Map, fields}, arity: :unknown}
      :unknown -> %{type: :Map, arity: :unknown}
    end
  end

  defp binding_for(%Identifier{name: name}, env) do
    case Env.get_var(env, name) do
      %{type: _, arity: _} = binding -> binding
      _ -> @unknown_binding
    end
  end

  defp binding_for(
         %List{elements: [%Identifier{name: :"<:"}, type1, type2]},
         env
       ) do
    case {parse_type(type1, env), parse_type(type2, env)} do
      {{:ok, t1}, {:ok, t2}} ->
        val = compatible_types?(t1, t2)
        %{type: {:Symbol, val}, arity: :unknown}

      _ ->
        %{type: {:Union, [{:Symbol, true}, {:Symbol, false}]}, arity: :unknown}
    end
  end

  defp binding_for(%List{elements: [%Identifier{name: name} | args]}, env) do
    case env |> Env.get_var(name) |> function_signature() do
      %{args: parameters, result: type} ->
        case infer_type_variables(args, parameters, env) do
          {:ok, substitutions} ->
            result_type = substitute_type(type, substitutions)
            %{type: result_type, arity: arity_for_type(result_type)}

          {:error, _} ->
            @unknown_binding
        end

      _ ->
        @unknown_binding
    end
  end

  defp binding_for(_value, _env), do: @unknown_binding

  defp arity_for_type({:Fn, arguments, _result}), do: length(arguments)
  defp arity_for_type(_type), do: :unknown

  defp function_signature(%{signature: signature}), do: signature

  defp function_signature(%{type: {:Fn, arguments, result}}),
    do: %{args: arguments, result: result}

  defp function_signature(_binding), do: nil

  defp list_element_type([]), do: :Any

  defp list_element_type(types) do
    alternatives =
      types
      |> Enum.flat_map(fn
        {:Union, members} -> members
        type -> [type]
      end)
      |> Enum.uniq()

    cond do
      :Any in alternatives -> :Any
      length(alternatives) == 1 -> hd(alternatives)
      true -> {:Union, alternatives}
    end
  end

  defp tuple_element_type(element, env), do: element |> binding_for(env) |> Map.fetch!(:type)

  defp binding_with_signature(binding, nil), do: binding

  defp binding_with_signature(binding, %{args: arguments, result: result} = signature) do
    %{binding | type: {:Fn, arguments, result}, arity: length(arguments)}
    |> Map.put(:signature, signature)
  end

  defp read_spec(%List{elements: [%Identifier{name: :spec}, %Identifier{} = name, type]}, env) do
    cond do
      name.name in @reserved_names ->
        error("identificador reservado #{name.name}", name.meta)

      Map.has_key?(env.defs, {env.current_module, name.name}) ->
        error("spec de #{name.name} deve vir antes do def", name.meta)

      true ->
        with {:ok, signature} <- parse_signature(type, env) do
          {:ok, name.name, signature}
        end
    end
  end

  defp read_spec(%List{meta: meta}, _env), do: error("spec inválida", meta)

  defp parse_signature(
         %List{elements: [%Identifier{name: :<>}, %Tuple{elements: variables}, signature]},
         env
       ) do
    with {:ok, type_env, names} <- bind_type_parameters(variables, Env.new(env)),
         {:ok, parsed} <- parse_signature(signature, type_env) do
      {:ok, Map.put(parsed, :type_vars, names)}
    end
  end

  defp parse_signature(
         %List{elements: [%Identifier{name: :<>}, %Identifier{} = variable, signature]},
         env
       ) do
    with :ok <- check_type_parameter(variable, env),
         {:ok, parsed} <-
           parse_signature(
             signature,
             Env.new(env) |> Env.put_type(variable.name, {:type_var, variable.name})
           ) do
      {:ok, Map.put(parsed, :type_vars, [variable.name])}
    end
  end

  defp parse_signature(
         %List{elements: [%Identifier{name: :->}, %Tuple{elements: args}, result]},
         env
       ) do
    with {:ok, argument_types} <- parse_types(args, env),
         {:ok, result_type} <- parse_type(result, env) do
      {:ok, %{args: argument_types, result: result_type}}
    end
  end

  defp parse_signature(type, _env), do: error("assinatura de função inválida", type.meta)

  defp parse_types(types, env) do
    Enum.reduce_while(types, {:ok, []}, fn type, {:ok, collected} ->
      case parse_type(type, env) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | collected]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  @doc "Verifica se o tipo t1 é subtipo de t2."
  def subtype?(t1_expr, t2_expr, env) do
    with {:ok, t1} <- parse_type(t1_expr, env),
         {:ok, t2} <- parse_type(t2_expr, env) do
      {:ok, compatible_types?(t1, t2)}
    end
  end

  def parse_type(type, _env) when is_atom(type) or (is_tuple(type) and not is_struct(type)),
    do: {:ok, type}

  def parse_type(%Identifier{name: name}, _env) when name in @primitive_types, do: {:ok, name}

  def parse_type(%Identifier{name: name, meta: meta}, env) do
    case Env.get_type(env, name) do
      nil -> error("tipo não declarado: #{name}", meta)
      %{params: _} -> error("tipo genérico #{name} exige argumentos", meta)
      type -> {:ok, type}
    end
  end

  def parse_type(%List{elements: [%Identifier{name: :List}, element]}, env) do
    with {:ok, type} <- parse_type(element, env), do: {:ok, {:List, type}}
  end

  def parse_type(
        %List{elements: [%Identifier{name: :->}, %Tuple{elements: arguments}, result]},
        env
      ) do
    with {:ok, argument_types} <- parse_types(arguments, env),
         {:ok, result_type} <- parse_type(result, env) do
      {:ok, {:Fn, argument_types, result_type}}
    end
  end

  def parse_type(%List{elements: [%Identifier{name: name} | alternatives], meta: meta}, env)
      when name in [:U, :u] do
    if alternatives == [] do
      error("união de tipos precisa de alternativas", meta)
    else
      with {:ok, types} <- parse_types(alternatives, env), do: {:ok, {:Union, types}}
    end
  end

  def parse_type(%List{elements: [%Identifier{name: :&} | requirements], meta: meta}, env) do
    if requirements == [] do
      error("interseção de tipos precisa de requisitos", meta)
    else
      with {:ok, types} <- parse_types(requirements, env), do: {:ok, {:Intersection, types}}
    end
  end

  def parse_type(%List{elements: [%Identifier{name: name} | arguments], meta: meta}, env) do
    case Env.get_type(env, name) do
      %{params: parameters, body: body} ->
        if length(arguments) == length(parameters) do
          with {:ok, types} <- parse_types(arguments, env) do
            substitutions = parameters |> Enum.zip(types) |> Map.new()
            {:ok, substitute_type(body, substitutions)}
          end
        else
          error("tipo #{name} espera #{length(parameters)} argumento(s)", meta)
        end

      nil ->
        error("tipo não declarado: #{name}", meta)

      _ ->
        error("tipo #{name} não aceita argumentos", meta)
    end
  end

  def parse_type(%Tuple{elements: elements}, env) do
    with {:ok, types} <- parse_types(elements, env), do: {:ok, {:Tuple, types}}
  end

  def parse_type(%AST.Map{pairs: pairs}, env) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {%AST.Literal{type: :Key, value: key}, value}, {:ok, types} ->
        case parse_type(value, env) do
          {:ok, type} -> {:cont, {:ok, Map.put(types, key, type)}}
          {:error, _} = error -> {:halt, error}
        end

      _, {:ok, _} ->
        {:halt, {:error, "chaves de tipos de mapa devem ser símbolos"}}
    end)
    |> case do
      {:ok, types} -> {:ok, {:Map, types}}
      error -> error
    end
  end

  def parse_type(%AST.Literal{type: :Key, value: name}, _env),
    do: {:ok, {:Symbol, name}}

  def parse_type(type, _env) do
    meta = if is_struct(type) or is_map(type), do: Map.get(type, :meta, %{}), else: %{}
    error("tipo desconhecido ou ainda não suportado", meta)
  end

  defp substitute_type({:type_var, name}, substitutions),
    do: Map.get(substitutions, name, :Any)

  defp substitute_type({:List, element}, substitutions),
    do: {:List, substitute_type(element, substitutions)}

  defp substitute_type({:Tuple, elements}, substitutions),
    do: {:Tuple, Enum.map(elements, &substitute_type(&1, substitutions))}

  defp substitute_type({:Map, fields}, substitutions) do
    {:Map, Map.new(fields, fn {key, type} -> {key, substitute_type(type, substitutions)} end)}
  end

  defp substitute_type({:Fn, arguments, result}, substitutions) do
    {:Fn, Enum.map(arguments, &substitute_type(&1, substitutions)),
     substitute_type(result, substitutions)}
  end

  defp substitute_type({:Union, types}, substitutions),
    do: {:Union, Enum.map(types, &substitute_type(&1, substitutions))}

  defp substitute_type({:Intersection, types}, substitutions),
    do: {:Intersection, Enum.map(types, &substitute_type(&1, substitutions))}

  defp substitute_type(type, _substitutions), do: type

  defp check_declared_value(value, env, nil, _meta), do: check(value, env, :expression)

  defp check_declared_value(
         %List{elements: [%Identifier{name: :_ffi} | _]} = value,
         env,
         %{args: argument_types},
         meta
       ) do
    with {:ok, rewritten, _} <- check(value, env, :expression) do
      %{arity: arity} = binding_for(value, env)

      if arity == length(argument_types),
        do: {:ok, rewritten, env},
        else: error("quantidade de parâmetros não corresponde à aridade do _ffi", meta)
    end
  end

  defp check_declared_value(
         %List{elements: [%Identifier{name: :fn} = head, %Tuple{elements: params, meta: tmeta} = tup | body]} = node,
         env,
         %{args: argument_types, result: result_type},
         meta
       ) do
    if tmeta[:variadic] || length(params) != length(argument_types) do
      error("quantidade de parâmetros não corresponde à spec", meta)
    else
      with {:ok, fn_env} <- bind_fn_params(tup, Env.new(env), argument_types),
           {:ok, rewritten_body, checked_env} <- check_sequence(body, fn_env, :local),
           :ok <- check_result_type(rewritten_body, checked_env, result_type, meta) do
        {:ok, %List{node | elements: [head, tup | rewritten_body]}, env}
      end
    end
  end

  defp check_declared_value(_value, _env, _signature, meta),
    do: error("spec de função requer um valor fn", meta)

  defp check_result_type(body, env, expected, meta) do
    actual = body |> Elixir.List.last() |> binding_for(env) |> Map.fetch!(:type)

    if compatible_types?(actual, expected),
      do: :ok,
      else:
        error(
          "retorno da função tem tipo #{inspect(actual)}, esperado #{inspect(expected)}",
          meta
        )
  end

  defp check_argument_types(head, args, env, meta) do
    binding = call_binding(head, env)

    case function_signature(binding) do
      %{args: expected_types} ->
        case infer_type_variables(args, expected_types, env) do
          {:ok, _} ->
            :ok

          {:error, {actual, expected}} ->
            error(
              "argumento de #{call_name(head)} tem tipo #{inspect(actual)}, esperado #{inspect(expected)}",
              meta
            )
        end

      _ ->
        :ok
    end
  end

  defp call_name(%Identifier{name: name}), do: name
  defp call_name(_head), do: "função"

  defp infer_type_variables(arguments, expected_types, env) do
    arguments
    |> Enum.zip(expected_types)
    |> Enum.reduce_while({:ok, %{}}, fn {argument, expected}, {:ok, substitutions} ->
      actual = argument |> binding_for(env) |> Map.fetch!(:type)

      case match_type(actual, expected, substitutions) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp match_type(:Any, _expected, substitutions), do: {:ok, substitutions}

  defp match_type(actual, {:type_var, name} = expected, substitutions) do
    case Map.fetch(substitutions, name) do
      {:ok, bound} ->
        if compatible_types?(actual, bound),
          do: {:ok, substitutions},
          else: {:error, {actual, expected}}

      :error ->
        {:ok, Map.put(substitutions, name, actual)}
    end
  end

  defp match_type({:List, actual}, {:List, expected}, substitutions),
    do: match_type(actual, expected, substitutions)

  defp match_type({:Tuple, actual}, {:Tuple, expected}, substitutions)
       when length(actual) == length(expected) do
    actual
    |> Enum.zip(expected)
    |> Enum.reduce_while({:ok, substitutions}, fn {element, required}, {:ok, current} ->
      case match_type(element, required, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp match_type({:Map, actual}, {:Map, expected}, substitutions) do
    Enum.reduce_while(expected, {:ok, substitutions}, fn {key, required}, {:ok, current} ->
      case Map.fetch(actual, key) do
        {:ok, field_type} ->
          case match_type(field_type, required, current) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _} = error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, {{:Map, actual}, {:Map, expected}}}}
      end
    end)
  end

  defp match_type(actual, expected, substitutions) do
    if compatible_types?(actual, expected),
      do: {:ok, substitutions},
      else: {:error, {actual, expected}}
  end

  def compatible_types?(:Any, _expected), do: true
  def compatible_types?(_actual, :Any), do: true

  def compatible_types?({:Union, alternatives}, expected),
    do: Enum.all?(alternatives, &compatible_types?(&1, expected))

  def compatible_types?(actual, {:Union, alternatives}),
    do: Enum.any?(alternatives, &compatible_types?(actual, &1))

  def compatible_types?(actual, {:Intersection, requirements}),
    do: Enum.all?(requirements, &compatible_types?(actual, &1))

  def compatible_types?({:Intersection, requirements}, expected) do
    Enum.any?(requirements, &compatible_types?(&1, expected)) or
      case merge_map_requirements(requirements) do
        {:ok, merged} -> compatible_types?({:Map, merged}, expected)
        :error -> false
      end
  end

  def compatible_types?({:Symbol, _value}, :Symbol), do: true

  def compatible_types?({:Tuple, actual}, {:Tuple, expected}) do
    length(actual) == length(expected) and
      Enum.zip(actual, expected)
      |> Enum.all?(fn {element, required} -> compatible_types?(element, required) end)
  end

  def compatible_types?({:Tuple, _elements}, :Tuple), do: true

  def compatible_types?({:Map, actual}, {:Map, expected}) do
    Enum.all?(expected, fn {key, required_type} ->
      case Map.fetch(actual, key) do
        {:ok, actual_type} -> compatible_types?(actual_type, required_type)
        :error -> false
      end
    end)
  end

  def compatible_types?({:Map, _fields}, :Map), do: true

  def compatible_types?({:List, actual}, {:List, expected}),
    do: compatible_types?(actual, expected)

  def compatible_types?({:List, _element}, :List), do: true

  def compatible_types?({:Fn, actual_args, actual_result}, {:Fn, expected_args, expected_result}) do
    length(actual_args) == length(expected_args) and
      Enum.zip(actual_args, expected_args)
      |> Enum.all?(fn {actual, expected} -> compatible_types?(expected, actual) end) and
      compatible_types?(actual_result, expected_result)
  end

  def compatible_types?(type, type), do: true
  def compatible_types?(_actual, _expected), do: false

  defp merge_map_requirements(types) do
    Enum.reduce_while(types, {:ok, %{}}, fn
      {:Map, fields}, {:ok, merged} ->
        combined =
          Map.merge(merged, fields, fn _key, left, right -> {:Intersection, [left, right]} end)

        {:cont, {:ok, combined}}

      _, {:ok, _} ->
        {:halt, :error}
    end)
  end

  defp check_arity(%Identifier{name: :list}, _actual, _env, _meta), do: :ok

  defp check_arity(%Identifier{name: name}, actual, env, meta) do
    case Env.get_var(env, name) do
      %{arity: expected} when is_integer(expected) and expected != actual ->
        error("#{name} espera #{expected} argumento(s), recebeu #{actual}", meta)

      %{arity: {:at_least, minimum}} when actual < minimum ->
        error("#{name} espera ao menos #{minimum} argumento(s), recebeu #{actual}", meta)

      _ ->
        :ok
    end
  end

  defp check_arity(%List{} = function, actual, env, meta) do
    case binding_for(function, env) do
      %{arity: expected} when is_integer(expected) and expected != actual ->
        error("função anônima espera #{expected} argumento(s), recebeu #{actual}", meta)

      %{arity: {:at_least, minimum}} when actual < minimum ->
        error("função anônima espera ao menos #{minimum} argumento(s), recebeu #{actual}", meta)

      _ ->
        :ok
    end
  end

  defp check_arity(_function, _actual, _env, _meta), do: :ok

  defp check_callability(head, env, meta) do
    case binding_for(head, env) do
      %{type: type} when type in [:Int, :Float, :Str, :Symbol, :Tuple, :Map, :List] ->
        error("valor do tipo #{inspect(type)} não pode ser chamado", meta)

      %{type: {type, _}} when type in [:Symbol, :Tuple, :Map, :List] ->
        error("valor do tipo #{inspect(type)} não pode ser chamado", meta)

      _ ->
        :ok
    end
  end

  defp error(message, meta) when is_map(meta),
    do: {:error, "#{message} na linha #{Map.get(meta, :line, "?")}"}

  defp error(message, _meta), do: {:error, message}
end
