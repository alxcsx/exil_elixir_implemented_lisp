defmodule Parser do
  @moduledoc """
  Ponto de entrada do analisador de código-fonte.
  Converte texto em AST bruta (Lexer -> SyntaxAnalyzer).
  """

  @doc "Recebe o código-fonte em string e devolve {:ok, forms} ou {:error, motivo}."
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- Parser.Lexer.run(source) do
      Parser.SyntaxAnalyzer.run(tokens)
    end
  end
end
