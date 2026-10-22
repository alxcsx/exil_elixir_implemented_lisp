defmodule Backend.Interpreter do
  @moduledoc """
  Interpretador simples para TypedLisp.

  Avalia a AST pós-expansão/anotação e serve de motor de avaliação
  em tempo de compilação para o sistema de macros e execução no REPL.
  """

  alias Core.AST
  alias Core.AST.{Identifier, List, Literal, Tuple}
  alias Core.Env
  alias Core.RuntimeEnv

  @doc "Cria um contexto de execução para o interpretador, referenciando o Prelude."
  def new_context(env \\ nil) do
    base = env || Pipeline.base_env()
    RuntimeEnv.from_compile_env(base)
  end

  def run(ast, %Env{} = compile_env) do
    runtime_env = RuntimeEnv.from_compile_env(compile_env)

    case run(ast, runtime_env) do
      {:ok, result, new_runtime_env} ->
        {:ok, result, %{compile_env | runtime_env: new_runtime_env}}

      error ->
        error
    end
  end

  def run(%AST.Module{body: forms}, %RuntimeEnv{} = env) do
    try do
      {result, new_env} = eval_sequence(forms, env)
      {:ok, result, new_env}
    rescue
      e in RuntimeError -> {:error, e.message}
      e in ArithmeticError -> {:error, Exception.message(e)}
    end
  end

  def run(ast, %RuntimeEnv{} = env) do
    try do
      {result, new_env} = eval(ast, env)
      {:ok, result, new_env}
    rescue
      e in RuntimeError -> {:error, e.message}
      e in ArithmeticError -> {:error, Exception.message(e)}
    end
  end

  def eval_sequence([], env), do: {nil, env}

  def eval_sequence(forms, %Env{} = compile_env) do
    runtime_env = RuntimeEnv.from_compile_env(compile_env)

    {result, new_runtime_env} = eval_sequence(forms, runtime_env)
    {result, %{compile_env | runtime_env: new_runtime_env}}
  end

  def eval_sequence(forms, %RuntimeEnv{} = env) do
    Enum.reduce(forms, {nil, env}, fn form, {_last_val, current_env} ->
      eval(form, current_env)
    end)
  end

  # Fallback caso receba Core.Env diretamente
  def eval(ast, %Env{} = compile_env) do
    runtime_env = RuntimeEnv.from_compile_env(compile_env)

    {result, new_runtime_env} = eval(ast, runtime_env)
    {result, %{compile_env | runtime_env: new_runtime_env}}
  end

  # Literais (inclui palavras-chave :true, :false, :nil)
  def eval(%Literal{value: val}, env), do: {val, env}

  # Identificadores gerais
  def eval(%Identifier{name: name} = node, env) do
    case get_var_value(env, name) do
      {:ok, val} ->
        {val, env}

      :error ->
        line = if is_map(node.meta), do: Map.get(node.meta, :line, "?"), else: "?"
        raise "variável não definida: #{name} na linha #{line}"
    end
  end

  # Tuplas
  def eval(%Tuple{elements: elements}, env) do
    {vals, new_env} =
      Enum.map_reduce(elements, env, fn elem, current_env ->
        eval(elem, current_env)
      end)

    {:erlang.list_to_tuple(vals), new_env}
  end

  # Mapas
  def eval(%AST.Map{pairs: pairs}, env) do
    {evaluated_pairs, new_env} =
      Enum.map_reduce(pairs, env, fn {k, v}, current_env ->
        {val_k, env1} = eval(k, current_env)
        {val_v, env2} = eval(v, env1)
        {{val_k, val_v}, env2}
      end)

    {Map.new(evaluated_pairs), new_env}
  end

  # Lista vazia
  def eval(%List{elements: []}, env), do: {[], env}

  # Chamadas com identificador no topo (despacha formas especiais ou chamadas)
  def eval(%List{elements: [%Identifier{name: name} | _]} = node, env) do
    eval_form(name, node, env)
  end

  # Chamada com expressão arbitrária na posição de função (ex: ((fn [x] x) 1))
  def eval(%List{elements: [head | args], meta: meta}, env) do
    eval_call(head, args, env, meta)
  end

  def eval(other, env), do: {other, env}

  # -- Formas especiais da linguagem

  defp eval_form(
         :def,
         %List{elements: [%Identifier{name: :def}, %Identifier{name: name}, expr]},
         env
       ) do
    {val, env1} = eval_def_value(name, expr, env)
    new_env = RuntimeEnv.put_def(env1, name, val)
    {val, new_env}
  end

  defp eval_form(:def, %List{meta: meta}, _env) do
    line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
    raise "def espera nome e expressão na linha #{line}"
  end

  defp eval_form(
         :fn,
         %List{elements: [%Identifier{name: :fn}, %Tuple{elements: params} | body]},
         env
       ) do
    closure = make_closure(params, body, env)
    {closure, env}
  end

  defp eval_form(:fn, _node, _env) do
    raise "fn espera parâmetros entre colchetes seguidos do corpo"
  end

  defp eval_form(
         :let,
         %List{elements: [%Identifier{name: :let}, %Tuple{elements: bindings} | body]},
         env
       ) do
    let_env =
      bindings
      |> Enum.chunk_every(2)
      |> Enum.reduce(RuntimeEnv.new(env), fn
        [%Identifier{name: name}, val_expr], current_env ->
          {val, next_env} = eval(val_expr, current_env)
          RuntimeEnv.put_var(next_env, name, val)

        _other, _acc ->
          raise "pares de let inválidos"
      end)

    {result, _} = eval_sequence(body, let_env)
    {result, env}
  end

  defp eval_form(:let, _node, _env) do
    raise "let espera vetor de vínculos seguido do corpo"
  end

  defp eval_form(
         :if,
         %List{elements: [%Identifier{name: :if}, cond_expr, then_expr, else_expr]},
         env
       ) do
    {cond_val, env1} = eval(cond_expr, env)

    if truthy?(cond_val) do
      eval(then_expr, env1)
    else
      eval(else_expr, env1)
    end
  end

  defp eval_form(:if, _node, _env) do
    raise "if espera condição, expressão then e expressão else"
  end

  defp eval_form(:list, %List{elements: [%Identifier{name: :list} | args]}, env) do
    Enum.map_reduce(args, env, &eval/2)
  end

  defp eval_form(
         :_ffi,
         %List{
           elements: [
             %Identifier{name: :_ffi},
             %Literal{value: mod},
             %Literal{value: fun},
             %Literal{value: arity}
           ]
         },
         env
       ) do
    ffi_fn = fn args ->
      if length(args) != arity do
        raise "aridade incorreta para _ffi #{mod}:#{fun}: esperado #{arity}, recebido #{length(args)}"
      end

      args =
        if mod in [Core.AST, Midfield.MacroExpander],
          do: args,
          else: Enum.map(args, &unwrap_literal/1)
      apply(mod, fun, args)
    end

    {ffi_fn, env}
  end

  defp eval_form(:_ffi, _node, _env) do
    raise "_ffi espera módulo, função e aridade"
  end

  defp eval_form(name, %List{elements: [%Identifier{name: name} | args], meta: meta}, env) do
    eval_call(%Identifier{name: name, meta: meta}, args, env, meta)
  end

  # -- Chamadas de função

  defp eval_call(head, args, env, meta) do
    {callee, env1} = eval(head, env)

    {evaluated_args, env2} =
      Enum.map_reduce(args, env1, fn arg, current_env ->
        eval(arg, current_env)
      end)

    result = apply_callee(callee, evaluated_args, meta)
    {result, env2}
  end

  defp eval_def_value(
         name,
         %List{elements: [%Identifier{name: :fn}, %Tuple{elements: params} | body]},
         env
       ) do
    closure = make_closure(params, body, env, name)
    {closure, env}
  end

  defp eval_def_value(_name, expr, env), do: eval(expr, env)

  defp make_closure(params, body, env, fn_name \\ nil) do
    param_names = Enum.map(params, & &1.name)
    arity = length(param_names)

    fn call_args ->
      if length(call_args) != arity do
        raise "aridade incorreta: esperado #{arity}, recebido #{length(call_args)}"
      end

      bindings =
        param_names
        |> Enum.zip(call_args)
        |> Map.new()

      fn_env =
        RuntimeEnv.new(env)
        |> RuntimeEnv.put_vars(bindings)
        |> then(fn current_env ->
          if fn_name do
            self_fn = make_closure(params, body, env, fn_name)
            RuntimeEnv.put_def(current_env, fn_name, self_fn)
          else
            current_env
          end
        end)

      {res, _} = eval_sequence(body, fn_env)
      res
    end
  end

  defp apply_callee(callee, evaluated_args, meta) when is_function(callee) do
    cond do
      :erlang.is_function(callee, 1) ->
        callee.(evaluated_args)

      :erlang.is_function(callee, length(evaluated_args)) ->
        apply(callee, evaluated_args)

      true ->
        {:arity, actual_arity} = :erlang.fun_info(callee, :arity)
        line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
        raise "aridade incorreta na linha #{line}: esperado #{actual_arity}, recebido #{length(evaluated_args)}"
    end
  end

  defp apply_callee(callee, _args, meta) do
    line = if is_map(meta), do: Map.get(meta, :line, "?"), else: "?"
    raise "não é uma função chamável na linha #{line}: #{inspect(callee)}"
  end

  defp get_var_value(env, name) do
    if RuntimeEnv.has_var?(env, name) do
      {:ok, RuntimeEnv.get_var(env, name)}
    else
      :error
    end
  end

  defp unwrap_literal(%Literal{value: val}), do: val
  defp unwrap_literal(val), do: val

  def truthy?(%Literal{type: :Key, value: val}), do: truthy?(val)
  def truthy?(val), do: val not in [false, nil]
end
