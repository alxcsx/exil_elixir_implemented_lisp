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
        output =
          case results do
            [single] -> single
            multiple -> multiple
          end

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

  defp is_balanced?(str) do
    counts =
      String.graphemes(str)
      |> Enum.reduce({0, 0, 0}, fn
        "(", {p, b, c} -> {p + 1, b, c}
        ")", {p, b, c} -> {p - 1, b, c}
        "[", {p, b, c} -> {p, b + 1, c}
        "]", {p, b, c} -> {p, b - 1, c}
        "{", {p, b, c} -> {p, b, c + 1}
        "}", {p, b, c} -> {p, b, c - 1}
        _, acc -> acc
      end)

    counts == {0, 0, 0}
  end
end
