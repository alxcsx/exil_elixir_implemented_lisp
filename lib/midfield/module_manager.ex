defmodule Midfield.ModuleManager do
  @moduledoc """
  Resolve as formas do parser em módulos; sobras viram :__main__.
  """

  alias Core.AST.{Identifier, List, Module}

  def identify_modules(forms) do
    {inner_modules_raw, loose_expressions} = Enum.split_with(forms, &def_module?/1)

    inner_modules =
      Enum.map(
        inner_modules_raw,
        fn %List{elements: [_kw, %Identifier{name: name} | body], meta: meta} ->
          %Module{name: name, body: body, meta: meta}
        end
      )

    modules =
      case loose_expressions do
        [] ->
          inner_modules

        _ ->
          inner_modules ++ [%Module{name: :__main__, body: loose_expressions, meta: %{line: 0}}]
      end

    {:ok, modules}
  end

  defp def_module?(%List{elements: [%Identifier{name: :"def-module"} | _]}), do: true
  defp def_module?(_), do: false
end
