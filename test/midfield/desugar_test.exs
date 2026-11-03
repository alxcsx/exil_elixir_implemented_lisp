defmodule Midfield.DesugarTest do
  use ExUnit.Case, async: true

  alias Core.AST.{Identifier, List, Tuple, Module}
  alias Midfield.Desugar

  defp id(name), do: %Identifier{name: name}
  defp lst(elements), do: %List{elements: elements}
  defp tup(elements), do: %Tuple{elements: elements}

  describe "run/1 and desugar!/1" do
    test "preserves simple fn parameters without variadic" do
      form = lst([id(:fn), tup([id(:x), id(:y)]), id(:x)])
      assert {:ok, result} = Desugar.run(form)

      assert %List{elements: [%Identifier{name: :fn}, %Tuple{elements: [x, y], meta: meta} | _]} =
               result

      assert x.name == :x
      assert y.name == :y
      assert is_nil(meta[:variadic])
    end

    test "normalizes variadic parameters into tuple with variadic metadata" do
      form = lst([id(:fn), tup([id(:head), id(:|), id(:tail)]), id(:head)])
      assert {:ok, result} = Desugar.run(form)

      assert %List{
               elements: [
                 %Identifier{name: :fn},
                 %Tuple{elements: [head, tail], meta: %{variadic: 1}}
                 | _
               ]
             } = result

      assert head.name == :head
      assert tail.name == :tail
    end

    test "supports zero fixed arguments for purely variadic fn [| rest]" do
      form = lst([id(:fn), tup([id(:|), id(:rest)]), id(:rest)])
      assert {:ok, result} = Desugar.run(form)

      assert %List{
               elements: [
                 %Identifier{name: :fn},
                 %Tuple{elements: [rest], meta: %{variadic: 0}}
                 | _
               ]
             } = result

      assert rest.name == :rest
    end

    test "rejects misplaced | in fn parameters" do
      # [a | b c]
      bad1 = lst([id(:fn), tup([id(:a), id(:|), id(:b), id(:c)]), id(:a)])
      assert {:error, msg1} = Desugar.run(bad1)
      assert msg1 =~ "parâmetros variádicos devem ter | apenas antes do parâmetro final"

      # [a |]
      bad2 = lst([id(:fn), tup([id(:a), id(:|)]), id(:a)])
      assert {:error, msg2} = Desugar.run(bad2)
      assert msg2 =~ "parâmetros variádicos devem ter | apenas antes do parâmetro final"

      # [|]
      bad3 = lst([id(:fn), tup([id(:|)]), id(:x)])
      assert {:error, msg3} = Desugar.run(bad3)
      assert msg3 =~ "parâmetros variádicos devem ter | apenas antes do parâmetro final"
    end

    test "desugars inside AST.Module body" do
      mod = %Module{
        name: :Sample,
        body: [
          lst([id(:fn), tup([id(:a), id(:|), id(:rest)]), id(:a)])
        ]
      }

      assert {:ok, %Module{name: :Sample, body: [desugared_fn]}} = Desugar.run(mod)

      assert %List{
               elements: [
                 %Identifier{name: :fn},
                 %Tuple{elements: [_, _], meta: %{variadic: 1}} | _
               ]
             } =
               desugared_fn
    end
  end
end
