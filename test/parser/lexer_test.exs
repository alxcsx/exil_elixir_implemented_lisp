defmodule Parser.LexerTest do
  use ExUnit.Case, async: true
  alias Parser.Lexer

  describe "Token generation" do
    test "tokenizes literals" do
      code = "42 -42 \"hello world\" :key 0.25 -3.14 0 00 01"

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:integer, 1, 42},
                  {:integer, 1, -42},
                  {:string, 1, "hello world"},
                  {:symbol, 1, :key},
                  {:float, 1, 0.25},
                  {:float, 1, -3.14},
                  {:integer, 1, 0},
                  {:integer, 1, 0},
                  {:integer, 1, 1}
                ]}
    end

    test "tokenizes structural characters" do
      code = "[ ] { } ( )"

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:"[", 1},
                  {:"]", 1},
                  {:"{", 1},
                  {:"}", 1},
                  {:"(", 1},
                  {:")", 1}
                ]}
    end
  end

  describe "text handling" do
    test "tracks line numbers correctly" do
      code = """
      (def a
      42)
      """

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:"(", 1},
                  {:identifier, 1, "def"},
                  {:identifier, 1, "a"},
                  {:integer, 2, 42},
                  {:")", 2}
                ]}
    end

    test "ignores whitespace and comments" do
      code = "(1 \t \n 3) ; this is a comment"

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:"(", 1},
                  {:integer, 1, 1},
                  {:integer, 2, 3},
                  {:")", 2}
                ]}
    end

    test "handles comment at end of input without trailing newline" do
      code = "42 ; comment without newline"

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:integer, 1, 42}
                ]}
    end

    test "tokenizes empty collections and empty string" do
      code = "() [] {} \"\""

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:"(", 1},
                  {:")", 1},
                  {:"[", 1},
                  {:"]", 1},
                  {:"{", 1},
                  {:"}", 1},
                  {:string, 1, ""}
                ]}
    end

    test "handles tokens adjacent to delimiters without spaces" do
      code = "(f[x]{:a 1})"

      assert Lexer.run(code) ==
               {:ok,
                [
                  {:"(", 1},
                  {:identifier, 1, "f"},
                  {:"[", 1},
                  {:identifier, 1, "x"},
                  {:"]", 1},
                  {:"{", 1},
                  {:symbol, 1, :a},
                  {:integer, 1, 1},
                  {:"}", 1},
                  {:")", 1}
                ]}
    end

    test "raises on unterminated string" do
      assert_raise RuntimeError, ~r/string não fechada/, fn ->
        Lexer.run("\"unfinished string")
      end
    end

    test "raises on colon alone" do
      assert_raise RuntimeError, ~r/':' sozinho na linha/, fn ->
        Lexer.run(":")
      end
    end
  end
end
