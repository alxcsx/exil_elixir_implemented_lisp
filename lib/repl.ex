defmodule REPL do
  def start(opts \\ []) do
    IO.puts("Starting REPL! (Type :q to exit)")
    cwd = File.cwd!()
    opts = Keyword.put_new(opts, :root, cwd)
    initial_env = Keyword.get_lazy(opts, :env, &Pipeline.base_env/0)
    loop(initial_env, opts)
  end

  defp loop(env, opts) do
    case read_multiline() do
      :eof ->
        IO.puts("Bye!")

      source ->
        case String.trim(source) do
          "" -> loop(env, opts)
          cmd when cmd in [":q", ":quit"] -> IO.puts("Bye!")
          code -> eval_and_loop(code, env, opts)
        end
    end
  end

  defp eval_and_loop(code, env, opts) do
    case Pipeline.run(code, Keyword.put(opts, :env, env)) do
      {:ok, results, new_env} ->
        output = List.last(results)
        IO.puts("=> #{format_output(output)}")
        loop(new_env, opts)

      {:error, err} ->
        IO.puts("Error: #{err}\n")
        loop(env, opts)
    end
  end

  def format_output(true), do: ":true"
  def format_output(false), do: ":false"

  def format_output(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ", ", &format_output/1) <> "]"

  def format_output(val), do: inspect(val)

  # Utilitário pro IO.gets não terminar caso os parenteses não estejam fechados
  defp read_multiline, do: read_multiline("")

  defp read_multiline(acc) do
    case IO.gets(if acc == "", do: "REPL>", else: "...") do
      line when is_binary(line) ->
        new_acc = acc <> line
        if is_balanced?(new_acc), do: new_acc, else: read_multiline(new_acc)

      :eof ->
        if acc == "", do: :eof, else: acc

      {:error, reason} ->
        IO.puts("\nIO Error #{reason}")
        acc
    end
  end

  def is_balanced?(str) when is_binary(str) do
    str
    |> String.to_charlist()
    |> count_brackets({0, 0, 0}, :normal)
  end

  defp count_brackets([], {p, b, c}, :normal), do: p <= 0 and b <= 0 and c <= 0
  defp count_brackets([], _counts, _state), do: false

  # In comment: ignores everything until newline
  defp count_brackets([?\n | rest], counts, :comment), do: count_brackets(rest, counts, :normal)
  defp count_brackets([_ | rest], counts, :comment), do: count_brackets(rest, counts, :comment)

  # In string: handle escaped quotes and closing quote
  defp count_brackets([?\\, _ | rest], counts, :string), do: count_brackets(rest, counts, :string)
  defp count_brackets([?" | rest], counts, :string), do: count_brackets(rest, counts, :normal)
  defp count_brackets([_ | rest], counts, :string), do: count_brackets(rest, counts, :string)

  # Normal mode
  defp count_brackets([?; | rest], counts, :normal), do: count_brackets(rest, counts, :comment)
  defp count_brackets([?" | rest], counts, :normal), do: count_brackets(rest, counts, :string)

  defp count_brackets([?( | rest], {p, b, c}, :normal), do: count_brackets(rest, {p + 1, b, c}, :normal)
  defp count_brackets([?) | rest], {p, b, c}, :normal), do: count_brackets(rest, {p - 1, b, c}, :normal)
  defp count_brackets([?[ | rest], {p, b, c}, :normal), do: count_brackets(rest, {p, b + 1, c}, :normal)
  defp count_brackets([?] | rest], {p, b, c}, :normal), do: count_brackets(rest, {p, b - 1, c}, :normal)
  defp count_brackets([?{ | rest], {p, b, c}, :normal), do: count_brackets(rest, {p, b, c + 1}, :normal)
  defp count_brackets([?} | rest], {p, b, c}, :normal), do: count_brackets(rest, {p, b, c - 1}, :normal)

  defp count_brackets([_ | rest], counts, :normal), do: count_brackets(rest, counts, :normal)
end
