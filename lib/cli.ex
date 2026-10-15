defmodule CLI do
  def main(args) do
    {opts, files, _} =
      OptionParser.parse(
        args,
        switches: [
          repl: :boolean,
          compile: :boolean,
          target: :string,
          root: :string,
          std: :string
        ]
      )

    mode = if opts[:compile], do: :compile, else: :interpret
    pipeline_opts = [mode: mode] ++ root_opts(opts)

    cond do
      opts[:repl] -> REPL.start(pipeline_opts)
      length(files) > 0 -> run_file(hd(files), pipeline_opts)
      true -> IO.puts("Invalid Operation")
    end
  end

  defp root_opts(opts) do
    [root: opts[:root], std: opts[:std]] |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp run_file(file, opts) do
    case Pipeline.run_file(file, opts) do
      {:ok, result, _env} -> IO.puts("=> #{inspect(result)}")
      {:error, err} -> IO.puts("Compiler Error: #{inspect(err)}")
    end
  end
end
