defmodule Core.TypeTest do
  use ExUnit.Case, async: true
  alias Core.Type

  describe "primitive_types/0" do
    test "retorna os tipos primitivos canônicos" do
      primitives = Type.primitive_types()
      assert :Any in primitives
      assert :Int in primitives
      assert :Float in primitives
      assert :Str in primitives
      assert :Symbol in primitives
      assert :List in primitives
      assert :Tuple in primitives
      assert :Map in primitives
    end
  end

  describe "subtype?/2" do
    test "regras com Any" do
      assert Type.subtype?(:Any, :Int)
      assert Type.subtype?(:Int, :Any)
      assert Type.subtype?(:Any, :Any)
      assert Type.subtype?({:Map, %{a: :Int}}, :Any)
    end

    test "regras primitivas e reflexividade" do
      assert Type.subtype?(:Int, :Int)
      assert Type.subtype?(:Float, :Float)
      assert Type.subtype?(:Str, :Str)
      assert Type.subtype?(:Symbol, :Symbol)
      refute Type.subtype?(:Int, :Str)
      refute Type.subtype?(:Str, :Int)
    end

    test "subtipagem de símbolos" do
      assert Type.subtype?({:Symbol, :ok}, {:Symbol, :ok})
      assert Type.subtype?({:Symbol, :ok}, :Symbol)
      refute Type.subtype?({:Symbol, :ok}, {:Symbol, :error})
      refute Type.subtype?(:Symbol, {:Symbol, :ok})
    end

    test "subtipagem de tuplas" do
      assert Type.subtype?({:Tuple, [:Int, :Str]}, {:Tuple, [:Int, :Str]})
      assert Type.subtype?({:Tuple, [:Int, :Str]}, {:Tuple, [:Any, :Any]})
      assert Type.subtype?({:Tuple, [:Int, :Str]}, :Tuple)
      refute Type.subtype?({:Tuple, [:Int, :Str]}, {:Tuple, [:Int]})
      refute Type.subtype?({:Tuple, [:Int]}, {:Tuple, [:Int, :Str]})
      refute Type.subtype?({:Tuple, [:Str]}, {:Tuple, [:Int]})
    end

    test "subtipagem de listas" do
      assert Type.subtype?({:List, :Int}, {:List, :Int})
      assert Type.subtype?({:List, :Int}, {:List, :Any})
      assert Type.subtype?({:List, :Int}, :List)
      refute Type.subtype?({:List, :Int}, {:List, :Str})
    end

    test "subtipagem estrutural de mapas (largura e profundidade)" do
      # Largura: subtipo pode ter mais campos
      assert Type.subtype?({:Map, %{a: :Int, b: :Str}}, {:Map, %{a: :Int}})
      refute Type.subtype?({:Map, %{a: :Int}}, {:Map, %{a: :Int, b: :Str}})
      assert Type.subtype?({:Map, %{a: :Int}}, :Map)

      # Profundidade: campos aninhados são subtipos
      nested_actual = {:Map, %{coords: {:Map, %{x: :Int, y: :Int, z: :Int}}}}
      nested_expected = {:Map, %{coords: {:Map, %{x: :Int, y: :Int}}}}
      assert Type.subtype?(nested_actual, nested_expected)
    end

    test "subtipagem de funções (contravariância nos parâmetros, covariância no retorno)" do
      num = {:Union, [:Int, :Float]}
      # fn_sub aceita qualquer Num e retorna Int
      fn_sub = {:Fn, [num], :Int}
      # fn_super aceita apenas Int e pode retornar qualquer Num
      fn_super = {:Fn, [:Int], num}

      assert Type.subtype?(fn_sub, fn_super)
      refute Type.subtype?(fn_super, fn_sub)

      assert Type.subtype?({:Fn, [:Int], :Int}, :Fn)
    end

    test "subtipagem com Uniões" do
      num_union = {:Union, [:Int, :Float]}
      assert Type.subtype?(:Int, num_union)
      assert Type.subtype?(:Float, num_union)
      refute Type.subtype?(:Str, num_union)

      # Subtipo é união: todas as alternativas devem ser subtipos
      assert Type.subtype?({:Union, [:Int, :Int]}, :Int)
      refute Type.subtype?({:Union, [:Int, :Str]}, :Int)
    end

    test "subtipagem com Interseções" do
      inter = {:Intersection, [{:Map, %{a: :Int}}, {:Map, %{b: :Str}}]}
      assert Type.subtype?(inter, {:Map, %{a: :Int}})
      assert Type.subtype?(inter, {:Map, %{b: :Str}})
      assert Type.subtype?(inter, {:Map, %{a: :Int, b: :Str}})
      # Disjoint primitive intersection is subtype of both members
      inter_prim = {:Intersection, [:Int, :Str]}
      assert Type.subtype?(inter_prim, :Int)
      assert Type.subtype?(inter_prim, :Str)
    end
  end

  describe "substitute/2" do
    test "substitui variáveis de tipo em estruturas aninhadas" do
      type = {:Map, %{val: {:type_var, :T}, items: {:List, {:type_var, :T}}}}
      substitutions = %{T: :Int}

      assert Type.substitute(type, substitutions) ==
               {:Map, %{val: :Int, items: {:List, :Int}}}
    end

    test "substitui em funções e uniões" do
      type = {:Fn, [{:type_var, :A}], {:Union, [{:type_var, :B}, :Str]}}
      substitutions = %{A: :Int, B: :Float}

      assert Type.substitute(type, substitutions) ==
               {:Fn, [:Int], {:Union, [:Float, :Str]}}
    end
  end

  describe "of_value/1 reflexão de tipos em tempo de execução" do
    test "primitivos" do
      assert Type.of_value(42) == :Int
      assert Type.of_value(3.14) == :Float
      assert Type.of_value("texto") == :Str
      assert Type.of_value(:status) == {:Symbol, :status}
      assert Type.of_value(true) == {:Symbol, true}
    end

    test "tuplas" do
      assert Type.of_value({1, "a", :ok}) == {:Tuple, [:Int, :Str, {:Symbol, :ok}]}
    end

    test "listas homogêneas e heterogêneas" do
      assert Type.of_value([]) == {:List, :Any}
      assert Type.of_value([1, 2, 3]) == {:List, :Int}
      assert Type.of_value([1, "a"]) == {:List, {:Union, [:Int, :Str]}}
    end

    test "mapas" do
      assert Type.of_value(%{name: "Alice", age: 30}) ==
               {:Map, %{name: :Str, age: :Int}}
    end

    defmodule TestStruct do
      defstruct [:id, :active]
    end

    test "structs Elixir são refletidas como mapas tipados" do
      struct_val = %TestStruct{id: 1, active: true}
      assert Type.of_value(struct_val) == {:Map, %{id: :Int, active: {:Symbol, true}}}
    end

    test "funções" do
      assert Type.of_value(fn x -> x end) == {:Fn, [:Any], :Any}
      assert Type.of_value(fn a, b -> a + b end) == {:Fn, [:Any, :Any], :Any}
    end
  end
end
