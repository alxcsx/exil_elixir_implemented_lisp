defmodule Midfield.TypeCheckerTest do
  use ExUnit.Case, async: true

  alias Core.AST
  alias Core.Env
  alias Midfield.{MacroExpander, TypeChecker}

  defp check(source) do
    {:ok, forms} = Parser.parse(source)

    prelude = %{Pipeline.base_env() | current_module: :__main__}
    module_env = Env.new(prelude)

    with {:ok, desugared} <- Parser.Desugar.run(%AST.Module{name: :__main__, body: forms}),
         {:ok, expanded, env} <- MacroExpander.run(desugared, module_env) do
      TypeChecker.run(expanded, env)
    end
  end

  defp checked!(source) do
    assert {:ok, %AST.Module{}, env} = check(source)
    env
  end

  defp assert_error(source, expected) do
    assert {:error, message} = check(source)
    assert message =~ expected
    message
  end

  describe "resolução de nomes e escopos" do
    test "rejeita uso sem declaração, informando o nome e a linha" do
      assert_error("(def x 1)\nunknown", "identificador não declarado: unknown na linha 2")
    end

    test "uma declaração posterior não valida um uso anterior" do
      assert_error("future\n(def future 1)", "identificador não declarado: future na linha 1")
    end

    test "def disponibiliza o nome para expressões seguintes, mas não aceita duplicação" do
      env = checked!("(def value 1) value")
      assert %{type: :Int} = Env.get_var(env, :value)
      assert_error("(def value 1) (def value 2)", "declaração duplicada de value")
    end

    test "nomes da linguagem não podem ser declarados pelo programa" do
      for name <- ["list", "def", "Int"] do
        assert_error("(def #{name} 1)", "identificador reservado")
      end
    end

    test "nomes aritméticos vêm do ambiente pai e podem ser sombreados no módulo" do
      env = checked!("(def + (fn [x] x)) (+ 1)")
      assert %{arity: 1} = Env.get_var(env, :+)
      assert_error("(def + (fn [x] x)) (+ 1 2)", "+ espera 1 argumento(s)")
    end

    test "a função pode referir-se ao próprio nome, mas um valor comum não" do
      checked!("(def loop (fn [x] (loop x)))")
      assert_error("(def value value)", "identificador não declarado: value")
    end

    test "parâmetros de fn enxergam o módulo, não escapam e não podem repetir nomes" do
      checked!("(def offset 1) (fn [x] (+ x offset))")
      assert_error("(fn [x x] x)", "declaração duplicada de x")
      assert_error("(fn [x] x) x", "identificador não declarado: x")
    end

    test "let permite sombreamento e bindings sequenciais sem vazamento" do
      checked!("(def x 1) (let [x 2 y x] y) x")
      assert_error("(let [x y y 1] x)", "identificador não declarado: y")
      assert_error("(let [x 1 x 2] x)", "declaração duplicada de x")
      assert_error("(let [x 1] x) x", "identificador não declarado: x")
    end

    test "tuplas e mapas validam usos" do
      # quote será consumido antes do checker quando o contrato do MacroExpander estiver pronto.
      # checked!("(quote missing)")
      assert_error("[missing]", "identificador não declarado: missing")
      assert_error("{:key missing}", "identificador não declarado: missing")
    end
  end

  describe "aridade e chamadas" do
    test "o pipeline disponibiliza operações aritméticas no ambiente pai" do
      assert {:ok, _results, env} = Pipeline.run("(+ 1 2)")
      assert %{type: {:Fn, [:Any, :Any], :Any}, arity: 2} = Env.get_var(env, :+)
    end

    test "operações aritméticas aceitam exatamente dois argumentos" do
      for name <- ["+", "-", "*", "/", "**"] do
        checked!("(#{name} 1 2)")
        assert_error("(#{name} 1)", "espera 2 argumento(s), recebeu 1")
        assert_error("(#{name} 1 2 3)", "espera 2 argumento(s), recebeu 3")
      end
    end

    test "funções declaradas, locais e anônimas mantêm sua aridade" do
      checked!("(def f (fn [x y] x)) (f 1 2)")
      assert_error("(def f (fn [x y] x)) (f 1)", "f espera 2 argumento(s)")
      assert_error("(let [f (fn [x] x)] (f))", "f espera 1 argumento(s)")
      assert_error("((fn [x] x) 1 2)", "função anônima espera 1 argumento(s)")
    end

    test "funções com parâmetro final após | aceitam os argumentos restantes" do
      checked!("(def first (fn [x | rest] x)) (first 1) (first 1 2 3)")
      checked!("(let [first (fn [x | rest] x)] (first 1 2))")
      assert_error("(def first (fn [x | rest] x)) (first)", "espera ao menos 1 argumento(s)")
    end

    test "um valor de tipo conhecido que não é função não pode ser chamado" do
      assert_error("(def answer 42) (answer 1)", "não pode ser chamado")
      assert_error("(def point [1 2]) (point 1)", "não pode ser chamado")
    end

    test "valores Any permanecem permissivos quando a aridade é desconhecida" do
      checked!("(fn [f] (f 1 2 3))")
    end
  end

  describe "tipos evidentes e listas" do
    test "infere tipos de literais e das estruturas com sintaxe própria" do
      env =
        checked!(
          "(def integer 1) (def decimal 1.5) (def text \"x\") " <>
            "(def symbol :ok) (def tuple [:ok 1]) (def record {:count 1})"
        )

      assert %{type: :Int} = Env.get_var(env, :integer)
      assert %{type: :Float} = Env.get_var(env, :decimal)
      assert %{type: :Str} = Env.get_var(env, :text)
      assert %{type: {:Symbol, :ok}} = Env.get_var(env, :symbol)
      assert %{type: {:Tuple, [{:Symbol, :ok}, :Int]}} = Env.get_var(env, :tuple)
      assert %{type: {:Map, %{count: :Int}}} = Env.get_var(env, :record)
    end

    test "let e if propagam o tipo quando a expressão permite identificá-lo" do
      env = checked!("(def a (let [x 1] x)) (def b (if :true \"yes\" \"no\"))")
      assert %{type: :Int} = Env.get_var(env, :a)
      assert %{type: :Str} = Env.get_var(env, :b)
      assert_error("(if :true 1)", "if espera exatamente 3 argumentos")
    end

    test "list aceita zero ou mais elementos e infere união para tipos diferentes" do
      env = checked!("(def empty (list)) (def ints (list 1 2 3)) (def mixed (list 1 \"a\" 2))")

      assert %{type: {:List, :Any}} = Env.get_var(env, :empty)
      assert %{type: {:List, :Int}} = Env.get_var(env, :ints)
      assert %{type: {:List, {:Union, [:Int, :Str]}}} = Env.get_var(env, :mixed)
    end

    test "assinatura de lista aceita os tipos declarados e rejeita outro elemento" do
      prefix = "(spec consume (-> [(List (U Int Str))] Int)) (def consume (fn [xs] 1))"
      checked!(prefix <> " (consume (list 1 \"a\"))")

      int_only = "(spec consume (-> [(List Int)] Int)) (def consume (fn [xs] 1))"
      checked!(int_only <> " (consume (list))")
      assert_error(int_only <> " (consume (list 1 \"a\"))", "argumento de consume")
    end
  end

  describe "assinaturas e aliases" do
    test "spec e def-type são consumidos sem chegar à AST devolvida" do
      source =
        "(def-type Count Int) " <>
          "(spec identity (-> [Count] Count)) (def identity (fn [x] x)) (identity 1)"

      assert {:ok,
              %AST.Module{
                body: [
                  %AST.List{elements: [%AST.Identifier{name: :def} | _]},
                  %AST.List{elements: [%AST.Identifier{name: :identity} | _]}
                ]
              }, env} = check(source)

      assert :Int = Env.get_type(env, :Count)
      assert %{signature: %{args: [:Int], result: :Int}} = Env.get_var(env, :identity)
    end

    test "_ffi mantém a definição para o backend e usa a aridade informada" do
      source = "(def eq (_ffi :erlang :== 2)) (eq 1 \"x\")"

      assert {:ok,
              %AST.Module{
                body: [
                  %AST.List{
                    elements: [
                      %AST.Identifier{name: :def},
                      %AST.Identifier{name: :eq},
                      %AST.List{elements: [%AST.Identifier{name: :_ffi} | _]}
                    ]
                  },
                  _call
                ]
              }, env} = check(source)

      assert %{type: {:Fn, [:Any, :Any], :Any}, arity: 2} = Env.get_var(env, :eq)
      assert_error(source <> " (eq 1)", "eq espera 2 argumento(s)")
    end

    test "spec de _ffi anota tipos e exige a mesma aridade" do
      source =
        "(def-type Bool (U :true :false)) " <>
          "(spec eq (-> [Any Any] Bool)) (def eq (_ffi :erlang :== 2)) (eq 1 1)"

      assert {:ok, %AST.Module{body: [_definition, _call]}, env} = check(source)
      assert %{arity: 2, signature: %{result: {:Union, _}}} = Env.get_var(env, :eq)

      assert_error(
        "(spec eq (-> [Any] Any)) (def eq (_ffi :erlang :== 2))",
        "não corresponde à aridade do _ffi"
      )
    end

    test "_ffi exige símbolos para módulo e função e aridade não negativa" do
      for source <- [
            "(def eq (_ffi erlang :== 2))",
            "(def eq (_ffi :erlang == 2))",
            "(def eq (_ffi :erlang :== -1))"
          ] do
        assert_error(source, "forma _ffi inválida")
      end
    end

    test "spec é imediatamente anterior ao def mesmo com linhas em branco" do
      env = checked!("(spec identity (-> [Int] Int))\n\n(def identity (fn [x] x))")
      assert %{arity: 1, signature: %{args: [:Int], result: :Int}} = Env.get_var(env, :identity)
    end

    test "spec sem def correspondente, separada dele ou posterior é inválida" do
      signature = "(spec identity (-> [Int] Int))"
      definition = "(def identity (fn [x] x))"

      assert_error(signature, "deve preceder imediatamente")
      assert_error(signature <> " (def x 1) " <> definition, "deve preceder imediatamente")
      assert_error(definition <> " " <> signature, "spec de identity deve vir antes")
    end

    test "spec verifica aridade declarada, argumento conhecido e retorno conhecido" do
      valid = "(spec identity (-> [Int] Int)) (def identity (fn [x] x))"
      checked!(valid <> " (identity 1)")
      assert_error(valid <> " (identity \"bad\")", "argumento de identity")

      assert_error(
        "(spec identity (-> [Int] Int)) (def identity (fn [x y] x))",
        "quantidade de parâmetros não corresponde à spec"
      )

      assert_error(
        "(spec identity (-> [Int] Str)) (def identity (fn [x] x))",
        "retorno da função tem tipo"
      )
    end

    test "Any permite argumentos e retornos cujo tipo não é conhecido" do
      checked!("(spec f (-> [Any] Int)) (def f (fn [x] 1)) (f \"text\")")
      checked!("(spec f (-> [Int] Int)) (def f (fn [x] (+ x 1)))")
    end

    test "aliases devem ser declarados antes do uso e não podem colidir com nomes existentes" do
      env = checked!("(def-type Count Int) (spec f (-> [Count] Count)) (def f (fn [x] x))")
      assert :Int = Env.get_type(env, :Count)

      assert_error("(def-type A B) (def-type B Int)", "tipo não declarado: B")
      assert_error("(def-type Int Str)", "nome de tipo reservado")
      assert_error("(def x 1) (def-type x Int)", "coincide com variável")
      assert_error("(def-type x Int) (def x 1)", "coincide com tipo")
    end

    test "qualquer símbolo literal tem tipo específico sem perder compatibilidade com Symbol" do
      source =
        "(def-type State (U :ready :done)) " <>
          "(spec accepts (-> [State] Symbol)) (def accepts (fn [value] value))"

      checked!(source <> " (accepts :ready) (accepts :done)")
      assert_error(source <> " (accepts :other)", "argumento de accepts")

      checked!(
        "(spec accepts (-> [Symbol] Symbol)) (def accepts (fn [value] value)) (accepts :other)"
      )
    end

    test "alias genérico instancia os parâmetros agrupados entre colchetes" do
      env =
        checked!(
          "(def-type (Pair [T U]) [T U]) (def-type IntText (Pair Int Str)) " <>
            "(def-type (Box [T]) {:value T}) (def-type IntBox (Box Int))"
        )

      assert {:Tuple, [:Int, :Str]} = Env.get_type(env, :IntText)
      assert {:Map, %{value: :Int}} = Env.get_type(env, :IntBox)

      assert_error("(def-type (Pair [T U]) [T U]) (def-type Bad (Pair Int))", "espera 2")
      assert_error("(def-type (Pair [T T]) [T T])", "tipo já declarado: T")
    end
  end

  describe "união, interseção e tipos estruturais" do
    test "spec genérica infere variáveis de tipo e rejeita usos incompatíveis da mesma variável" do
      source = "(spec first (<> [T U] (-> [T U] T))) (def first (fn [a b] a))"
      env = checked!(source <> " (def n (first 1 \"x\")) (def s (first \"x\" 1))")
      assert %{type: :Int} = Env.get_var(env, :n)
      assert %{type: :Str} = Env.get_var(env, :s)

      same = "(spec same (<> T (-> [T T] T))) (def same (fn [a b] a))"
      assert_error(same <> " (same 1 \"x\")", "argumento de same")
    end

    test "união aceita cada alternativa, mas rejeita outro marcador ou tipo" do
      source =
        "(def-type Ok [:ok Int]) (def-type Failure [:error Str]) " <>
          "(def-type Result (U Ok Failure)) " <>
          "(spec accept (-> [Result] Int)) (def accept (fn [result] 1))"

      checked!(source <> " (accept [:ok 1]) (accept [:error \"bad\"])")
      assert_error(source <> " (accept [:other 1])", "argumento de accept")
      assert_error(source <> " (accept [:ok \"bad\"])", "argumento de accept")
    end

    test "interseção exige todos os campos, permite campos extras e verifica mapas aninhados" do
      source =
        "(def-type Seats {:seats Int}) (def-type Wings {:wings Float}) " <>
          "(def-type Plane (& Seats Wings)) " <>
          "(spec accept (-> [Plane] Int)) (def accept (fn [plane] 1))"

      checked!(source <> " (accept {:seats 4 :wings 2.0 :name \"A\"})")
      assert_error(source <> " (accept {:seats 4})", "argumento de accept")
      assert_error(source <> " (accept {:seats 4 :wings \"wrong\"})", "argumento de accept")

      nested =
        "(spec accept (-> [{:plane {:seats Int}}] Int)) " <>
          "(def accept (fn [item] 1))"

      checked!(nested <> " (accept {:plane {:seats 4 :wings 2.0}})")
      assert_error(nested <> " (accept {:plane {:wings 2.0}})", "argumento de accept")
    end
  end

  describe "funções como valores" do
    test "uma assinatura de função pode ser tipo de parâmetro e de alias" do
      source =
        "(def-type Converter (-> [Int] Int)) " <>
          "(spec apply (-> [Converter Int] Int)) " <>
          "(def apply (fn [f x] (f x)))"

      env = checked!(source <> " (apply (fn [x] 1) 2)")
      assert %{type: {:Fn, [{:Fn, [:Int], :Int}, :Int], :Int}} = Env.get_var(env, :apply)

      assert_error(source <> " (apply (fn [x y] 1) 2)", "argumento de apply")
      assert_error(source <> " (apply (fn [x] 1) \"bad\")", "argumento de apply")
    end

    test "uma função retornada por outra mantém aridade e tipos dos argumentos" do
      source =
        "(spec make (-> [] (-> [Int] Str))) " <>
          "(def make (fn [] (fn [x] \"ok\")))"

      checked!(source <> " ((make) 1)")
      assert_error(source <> " ((make) 1 2)", "espera 1 argumento(s)")
      assert_error(source <> " ((make) \"bad\")", "argumento")
    end

    test "entrada mais geral e retorno mais específico permitem substituição" do
      source =
        "(def-type Narrow {:value Str}) (def-type Wide {:value Str :other Int}) " <>
          "(spec candidate (-> [Narrow] Wide)) " <>
          "(def candidate (fn [x] {:value \"ok\" :other 1})) " <>
          "(spec use (-> [(-> [Wide] Narrow)] Narrow)) " <>
          "(def use (fn [f] (f {:value \"ok\" :other 1})))"

      checked!(source <> " (use candidate)")
    end

    test "entrada mais restrita não substitui uma função que aceita entrada geral" do
      source =
        "(def-type Narrow {:value Str}) (def-type Wide {:value Str :other Int}) " <>
          "(spec candidate (-> [Wide] Narrow)) " <>
          "(def candidate (fn [x] {:value \"ok\"})) " <>
          "(spec use (-> [(-> [Narrow] Narrow)] Narrow)) " <>
          "(def use (fn [f] (f {:value \"ok\"})))"

      assert_error(source <> " (use candidate)", "argumento de use")
    end

    test "retorno mais geral não substitui uma função que promete retorno específico" do
      source =
        "(def-type Narrow {:value Str}) (def-type Wide {:value Str :other Int}) " <>
          "(spec candidate (-> [Narrow] Narrow)) " <>
          "(def candidate (fn [x] {:value \"ok\"})) " <>
          "(spec use (-> [(-> [Narrow] Wide)] Wide)) " <>
          "(def use (fn [f] (f {:value \"ok\"})))"

      assert_error(source <> " (use candidate)", "argumento de use")
    end
  end

  describe "verificação estática de subtipagem com <:" do
    test "compara tipos de mapas com largura e profundidade e reescreve para :true" do
      source = "(<: {:x {:a Int :b Int} :y {:m Int}} {:x {:a Int} :y {}})"

      assert {:ok, %Core.AST.Module{body: [%Core.AST.Literal{type: :Key, value: true}]}, _env} =
               check(source)
    end

    test "reescreve para :false quando não é subtipo" do
      source = "(<: {:x {:a Int} :y {}} {:x {:a Int :b Int} :y {:m Int}})"

      assert {:ok, %Core.AST.Module{body: [%Core.AST.Literal{type: :Key, value: false}]}, _env} =
               check(source)
    end

    test "compara tipos nomeados com def-type" do
      source =
        "(def-type Narrow {:value Str}) (def-type Wide {:value Str :other Int}) " <>
          "(<: Wide Narrow)"

      assert {:ok, %Core.AST.Module{body: [%Core.AST.Literal{type: :Key, value: true}]}, _env} =
               check(source)
    end

    test "rejeita aridade incorreta de <:" do
      assert_error("(<: Int)", "<: espera exatamente 2 argumentos")
      assert_error("(<: Int Str Any)", "<: espera exatamente 2 argumentos")
    end

    test "rejeita tipo não declarado em <:" do
      assert_error("(<: Invalido Int)", "tipo não declarado: Invalido")
    end
  end

  describe "verificação estática de supertipagem com :>" do
    test "avalia supertipagem estrutural em tempo de compilação" do
      source = "(:> {:x {:a Int} :y {}} {:x {:a Int :b Int} :y {:m Int}})"

      assert {:ok, %Core.AST.Module{body: [%Core.AST.Literal{type: :Key, value: true}]}, _env} =
               check(source)
    end

    test "produz false quando o tipo não é supertipo" do
      source = "(:> {:x {:a Int :b Int} :y {:m Int}} {:x {:a Int} :y {}})"

      assert {:ok, %Core.AST.Module{body: [%Core.AST.Literal{type: :Key, value: false}]}, _env} =
               check(source)
    end

    test "rejeita aridade incorreta de :>" do
      assert_error("(:> Int)", ":> espera exatamente 2 argumentos")
      assert_error("(:> Int Str Any)", ":> espera exatamente 2 argumentos")
    end

    test "rejeita tipo não declarado em :>" do
      assert_error("(:> Invalido Int)", "tipo não declarado: Invalido")
    end
  end
end
