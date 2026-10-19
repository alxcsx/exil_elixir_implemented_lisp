defmodule Backend.Interpreter do
  @moduledoc "Implementação do interpretador LISP em Elixir"

  def run(ast, env \\ %{}) do # cria uma função publica, que recebe dois parametros: ast e o env
    {resultado, novo_env} = do_eval(ast, env)

    # Devolve no padrão esperado pelo pipeline
    {:ok, resultado, novo_env}
  end

  # 1- Avaliar um Literal (números, strings, booleanos)
  # O código desempacota a Struct e devolve apenas o valor puro.
  defp do_eval(%Core.AST.Literal{value: valor}, env) do # defp cria uma função privada
    {valor, env}
  end

  # 2. Busca de variável (Identifier -> procura o valor no env)
  defp do_eval(%Core.AST.Identifier{name: id}, env) do
    case Map.fetch(env, id) do
      {:ok, valor} -> {valor, env}
      :error -> raise "Variável não definida: #{id}"
    end
  end

  # 3. Declaração de variável global (def nome valor)
  defp do_eval(%Core.AST.List{elements: [%Core.AST.Identifier{name: :def}, %Core.AST.Identifier{name: var_name}, expr]}, env) do
    # Avalia a expressão para obter o valor final
    {valor, env_atualizado} = do_eval(expr, env)

    # Insere o par {var_name, valor} no mapa de memória
    novo_env = Map.put(env_atualizado, var_name, valor)

    # Retorna o valor atribuído e o ambiente atualizado
    {valor, novo_env}
  end

  # 4. Condicional (if condicao then_expr else_expr)
  defp do_eval(%Core.AST.List{elements: [%Core.AST.Identifier{name: :if}, cond_expr, then_expr, else_expr]}, env) do
    {cond_val, env_atualizado} = do_eval(cond_expr, env)

    if cond_val do
      do_eval(then_expr, env_atualizado)
    else
      do_eval(else_expr, env_atualizado)
    end
  end

  # 5. Atribuição local (let var_name val_expr body_expr)
  defp do_eval(%Core.AST.List{elements: [%Core.AST.Identifier{name: :let}, %Core.AST.Identifier{name: var_name}, val_expr, body_expr]}, env) do
    # Avalia a expressão do valor
    {val, env_atualizado} = do_eval(val_expr, env)

    # Anota a variável em uma CÓPIA temporária do caderno (escopo local)
    local_env = Map.put(env_atualizado, var_name, val)

    # Avalia o corpo principal usando o caderno local
    {res, _env_local_final} = do_eval(body_expr, local_env)

    # Retorna o resultado do corpo, mas devolve o env original (a variável local NÃO vaza para fora)
    {res, env_atualizado}
  end

  # 6. Operações nativas (_ffi funcao_elixir arg1 arg2 ...)
  defp do_eval(%Core.AST.List{elements: [%Core.AST.Identifier{name: :_ffi}, %Core.AST.Identifier{name: fun_name} | args]}, env) do
    {evaled_args, env_final} = eval_list(args, env, [])

    # Chama a função nativa do Elixir (ex: Kernel.+ ou Kernel.-)
    resultado = apply(Kernel, fun_name, evaled_args)
    {resultado, env_final}
  end

  # 7. Funções anônimas (fn (params) body)
  defp do_eval(%Core.AST.List{elements: [%Core.AST.Identifier{name: :fn}, %Core.AST.List{elements: params}, body_expr]}, env) do
    param_names = Enum.map(params, fn %Core.AST.Identifier{name: name} -> name end)
    closure = {:closure, param_names, body_expr, env}
    {closure, env}
  end

  # 8. Chamada de função genérica (funcao arg1 arg2 ...)
  defp do_eval(%Core.AST.List{elements: [fun_expr | args]}, env) do
    {closure, env_atualizado} = do_eval(fun_expr, env)
    {evaled_args, env_final} = eval_list(args, env_atualizado, [])

    case closure do
      {:closure, param_names, body_expr, closure_env} ->
        local_bindings = Enum.zip(param_names, evaled_args) |> Enum.into(%{})
        call_env = Map.merge(closure_env, local_bindings)
        {res, _env_da_chamada} = do_eval(body_expr, call_env)
        {res, env_final}

      _ ->
        raise "O elemento fornecido não é uma função executável"
    end
  end

  # --- FUNÇÕES AUXILIARES ---

  # Função auxiliar para avaliar uma lista de argumentos sequencialmente
  defp eval_list([], env, acc) do
    {Enum.reverse(acc), env}
  end

  defp eval_list([head | tail], env, acc) do
    {val, novo_env} = do_eval(head, env)
    eval_list(tail, novo_env, [val | acc])
  end

end
