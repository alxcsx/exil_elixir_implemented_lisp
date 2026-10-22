defmodule Core.Params do
  @moduledoc false

  alias Core.AST.Identifier

  def parse(parameters) do
    {fixed, tail} = Enum.split_while(parameters, &identifier?/1)

    case tail do
      [] -> shape(fixed, nil)
      [%Identifier{name: :|}, %Identifier{} = rest] -> shape(fixed, rest)
      _ -> {:error, "parâmetros devem ser identificadores, com | apenas antes do parâmetro final"}
    end
  end

  defp shape(fixed, rest) do
    names = Enum.map(fixed, & &1.name) ++ if(rest, do: [rest.name], else: [])

    case names -- Enum.uniq(names) do
      [] -> {:ok, %{fixed: fixed, rest: rest}}
      [name | _] -> {:error, "declaração duplicada de #{name}"}
    end
  end

  defp identifier?(%Identifier{name: name}) when name != :|, do: true
  defp identifier?(_parameter), do: false
end
