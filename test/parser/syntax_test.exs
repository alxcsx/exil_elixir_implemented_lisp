defmodule SyntaxTest do
  use ExUnit.Case, async: true
  alias Core.AST.{Literal, Identifier, List, Tuple, Map}

  defp parse!(code) do
    {:ok, tokens} = Parser.Lexer.run(code)
    {:ok, raw_ast} = Parser.SyntaxAnalyzer.run(tokens)
    raw_ast
  end

  describe "Literals" do
    test "parses integers and floats" do
      assert [%Literal{type: :Int, value: 123}] = parse!("123")
      assert [%Literal{type: :Int, value: -42}] = parse!("-42")
      assert [%Literal{type: :Float, value: 3.14}] = parse!("3.14")
      assert [%Literal{type: :Float, value: -0.001}] = parse!("-0.001")
    end

    test "parses strings" do
      assert [%Literal{type: :Str, value: "hello world"}] = parse!("\"hello world\"")
    end

    test "parse strings with escape sequences" do
      assert [%Literal{type: :Str, value: "\"hello\""}] = parse!("\"\\\"hello\\\"\"")

      assert [%Literal{type: :Str, value: "line 1\nline 2"}] = parse!("\"line 1\\nline 2\"")
    end

    test "parses keywords" do
      assert [%Literal{type: :Key, value: :status}] = parse!(":status")
      assert [%Literal{type: :Key, value: :"is-valid?"}] = parse!(":is-valid?")

      assert [%Literal{type: :Key, value: :"*global-config*"}] = parse!(":*global-config*")

      assert [%Literal{type: :Key, value: :"123"}] = parse!(":123")
    end
  end

  describe "Identifiers" do
    test "parses standard symbols" do
      assert [%Identifier{name: :foo}] = parse!("foo")
    end

    test "parses lisp-specific operators and characters" do
      assert [%Identifier{name: :+}] = parse!("+")
      assert [%Identifier{name: :<=}] = parse!("<=")

      assert [%Identifier{name: :"is-empty?"}] = parse!("is-empty?")
      assert [%Identifier{name: :update!}] = parse!("update!")
      assert [%Identifier{name: :"*global-var*"}] = parse!("*global-var*")
      assert [%Identifier{name: :"my-var"}] = parse!("my-var")
    end
  end

  describe "Collections" do
    test "parses lists" do
      assert [
               %List{
                 elements: [
                   %Identifier{name: :+},
                   %Literal{type: :Int, value: 1},
                   %Literal{type: :Int, value: 2}
                 ]
               }
             ] = parse!("(+ 1 2)")
    end

    test "parses tuples" do
      assert [
               %Tuple{
                 elements: [
                   %Identifier{name: :a},
                   %Literal{type: :Int, value: 10}
                 ]
               }
             ] = parse!("[a 10]")
    end

    test "parses maps with pairs" do
      assert [
               %Map{
                 pairs: [
                   {%Literal{type: :Key, value: :a}, %Literal{type: :Int, value: 1}},
                   {%Literal{type: :Key, value: :b}, %Literal{type: :Int, value: 2}}
                 ]
               }
             ] = parse!("{ :a 1 :b 2 }")
    end

    test "parses nested structures" do
      assert [
               %List{
                 elements: [
                   %Identifier{name: :def},
                   %Identifier{name: :"my-map"},
                   %Map{
                     pairs: [
                       {%Literal{type: :Key, value: :coords},
                        %Tuple{
                          elements: [
                            %Literal{type: :Int, value: 0},
                            %Literal{type: :Int, value: 0}
                          ]
                        }}
                     ]
                   }
                 ]
               }
             ] = parse!("(def my-map {:coords [0 0]})")
    end
  end

  describe "Line Metadata" do
    test "injects line numbers correctly" do
      code = """
      (def a 1)
      (+ a 2)
      """

      assert [
               %List{meta: %{line: 1}},
               %List{meta: %{line: 2}}
             ] = parse!(code)
    end
  end

  describe "Error Handling & Edge Cases" do
    test "parses empty collections" do
      assert [%List{elements: []}] = parse!("()")
      assert [%Tuple{elements: []}] = parse!("[]")
      assert [%Map{pairs: []}] = parse!("{}")
    end

    test "fails with unclosed parenthesis" do
      assert {:error, msg} = Parser.parse("(def a 1")
      assert msg =~ "faltou ')'"
    end

    test "fails with unclosed bracket" do
      assert {:error, msg} = Parser.parse("[1 2")
      assert msg =~ "faltou ']'"
    end

    test "fails with unclosed brace" do
      assert {:error, msg} = Parser.parse("{:a 1")
      assert msg =~ "faltou '}'"
    end

    test "fails with mismatched delimiters" do
      # In Parser.SyntaxAnalyzer, encountering closer without opening raises unexpected closer
      assert {:error, msg} = Parser.parse("([)]")
      assert msg =~ "inesperado"
    end

    test "fails with odd number of elements in map" do
      assert {:error, msg} = Parser.parse("{:a 1 :b}")
      assert msg =~ "número ímpar"
    end

    test "fails with unexpected closing delimiter" do
      assert {:error, msg} = Parser.parse(")")
      assert msg =~ "inesperado"
    end
  end
end
