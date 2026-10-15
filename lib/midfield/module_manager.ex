defmodule Midfield.ModuleManager do
  @moduledoc """
  Resolve as formas do parser em módulos, descobre arquivos e monta o
  plano de compilação.

  `.exl` é módulo: raiz em `.exil`/`--root`/dir do arquivo, importa por nome
  de registry. `.exls` é script: sem raiz, importa por caminho relativo e só
  usa o registry para std; o nome vem do basename (`util.exls` -> `:Util`).

  Formas soltas pertencem ao módulo do arquivo (caminho relativo à raiz);
  `(def-module Nome ...)` usa o nome declarado e aninhamento compõe (`A/B`).
  Imports são resolvidos no topo do módulo. Sem caminho, vale `:__main__`.
  """

  alias Core.AST.{Identifier, List, Literal, Module}
  alias Core.Env

  @extension ".exl"
  @script_extension ".exls"
  @root_marker ".exil"
  @segment ~r/^[a-z][a-z0-9]*([_-][a-z0-9]+)*$/

  def identify_modules(forms, file_module \\ nil) do
    {declared, loose} = extract_modules(forms, nil)
    modules = declared ++ main_module(loose, file_module)

    case duplicate_module(modules) do
      nil -> {:ok, modules}
      name -> {:error, "módulo duplicado: #{name}"}
    end
  end

  @doc "Ordena por imports e acusa ciclos; imports de fora da lista são ignorados."
  def order(modules) do
    by_name = Map.new(modules, &{&1.name, &1})
    deps = Map.new(modules, &{&1.name, deps_of(&1, by_name)})

    case visit_all(Enum.map(modules, & &1.name), deps, %{}, []) do
      {:ok, ordered} -> {:ok, Enum.map(ordered, &Map.fetch!(by_name, &1))}
      {:error, _} = error -> error
    end
  end

  @doc """
  Nome do módulo pelo caminho relativo a `root`:
  `std/math_utils.exl` -> `:"Std/MathUtils"`.
  """
  def derive_name(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    relative = Path.relative_to(path, root)

    if relative == path do
      {:error, "arquivo fora da raiz: #{path}"}
    else
      relative
      |> Path.rootname()
      |> String.split("/")
      |> segments_name()
    end
  end

  defp segments_name(segments) do
    case Enum.find(segments, &(not Regex.match?(@segment, &1))) do
      nil -> {:ok, segments |> Enum.map_join("/", &pascal_case/1) |> String.to_atom()}
      segment -> {:error, "segmento de arquivo inválido: #{segment}"}
    end
  end

  @doc "Registra no Env os módulos definidos nos `.exl` sob `dir`; duplicados e nomes inválidos são erro."
  def discover(dir, env) do
    dir
    |> Path.join("**/*#{@extension}")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, env}, fn path, {:ok, env} ->
      case register_file(path, dir, env) do
        {:ok, env} -> {:cont, {:ok, env}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # -- Carregamento

  @doc "Raiz: `:root`, senão o primeiro `.exil` acima, senão o diretório do arquivo."
  def root_for(path, opts \\ []) do
    expanded = Path.expand(path)
    dir = Path.dirname(expanded)

    case Keyword.get(opts, :root) do
      nil -> {:ok, find_root(dir) || dir}
      root -> {:ok, Path.expand(root)}
    end
  end

  @doc "Plano `[{módulo, arquivo}]` da fonte e dependências, dependências primeiro."
  def load_plan(source, env, opts \\ []) do
    with {:ok, env} <- ensure_discovered(opts[:std], env),
         {:ok, ctx} <- source_ctx(env, opts),
         {:ok, name} <- entry_name(ctx),
         {:ok, plan, env} <- load_forms(name, source, ctx, env, [], false) do
      plan = Enum.uniq_by(plan, fn {module, path} -> {module.name, path} end)

      case duplicate_plan(plan) do
        nil -> {:ok, plan, env}
        {name, paths} -> {:error, "módulo duplicado: #{name} (#{Enum.join(paths, ", ")})"}
      end
    end
  end

  defp source_ctx(%{file: file}, opts) when is_binary(file) do
    file = Path.expand(file)
    file_ctx(file, opts, Path.dirname(file))
  end

  defp source_ctx(_env, opts) do
    base = Path.expand(Keyword.get(opts, :root) || File.cwd!())
    {:ok, %{file: nil, root: nil, base: base, kind: :script, opts: opts}}
  end

  defp entry_name(%{file: nil}), do: {:ok, :__main__}
  defp entry_name(%{file: file, kind: :script}), do: script_name(file)
  defp entry_name(%{file: file, root: root}), do: derive_name(file, root)

  defp file_ctx(path, opts, base) do
    case Path.extname(path) do
      @extension ->
        with {:ok, root} <- root_for(path, opts) do
          {:ok, %{file: path, root: root, base: root, kind: :module, opts: opts}}
        end

      @script_extension ->
        {:ok, %{file: path, root: nil, base: base, kind: :script, opts: opts}}

      other ->
        {:error, "extensão desconhecida: #{other}"}
    end
  end

  defp load_file(name, path, ctx, env, stack, skip_loaded?) do
    with {:ok, source} <- File.read(path) do
      load_forms(name, source, ctx, env, stack, skip_loaded?)
    end
  end

  defp load_forms(name, source, ctx, env, stack, skip_loaded?) do
    path = ctx.file

    cond do
      path != nil and path in stack ->
        {:error, "dependência circular: #{cycle_path(stack, path, ctx)}"}

      skip_loaded? and path != nil and Env.loaded?(env, path) ->
        {:ok, [], env}

      true ->
        with {:ok, env} <- ensure_discovered(ctx.root, env),
             {:ok, forms} <- parse(source),
             {:ok, modules} <- identify_modules(forms, name),
             modules = stamp_file(modules, path),
             {:ok, modules} <- order(modules),
             {:ok, modules, deps} <- resolve_imports(modules, ctx, env),
             {:ok, plan, env} <- load_deps(deps, env, [path | stack]) do
          {:ok, plan ++ Enum.map(modules, &{&1, path}), env}
        end
    end
  end

  defp load_deps(deps, env, stack) do
    Enum.reduce_while(deps, {:ok, [], env}, fn {name, path, ctx}, {:ok, plan, env} ->
      case load_file(name, path, ctx, env, stack, true) do
        {:ok, more, env} -> {:cont, {:ok, plan ++ more, env}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_imports(modules, ctx, env) do
    ctx = Map.merge(ctx, %{env: env, unit: MapSet.new(Enum.map(modules, & &1.name))})

    Enum.reduce_while(modules, {:ok, [], []}, fn %Module{} = module, {:ok, acc, deps} ->
      case resolve_body(module.body, ctx) do
        {:ok, body, new_deps} ->
          {:cont, {:ok, acc ++ [%Module{module | body: body}], deps ++ new_deps}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, modules, deps} ->
        {:ok, modules, Enum.uniq_by(deps, fn {_name, path, _ctx} -> path end)}

      {:error, _} = error ->
        error
    end
  end

  # Import com string vira nome de módulo antes de chegar no expander.
  defp resolve_body(forms, ctx) do
    Enum.reduce_while(forms, {:ok, [], []}, fn form, {:ok, acc, deps} ->
      case resolve_form(form, ctx) do
        {:ok, form, new_deps} -> {:cont, {:ok, acc ++ [form], deps ++ new_deps}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_form(
         %List{
           elements: [%Identifier{name: :import} = head, %Literal{type: :Str, value: rel} | rest]
         } = form,
         ctx
       ) do
    with {:ok, name, path, dep_ctx} <- resolve_path(rel, ctx) do
      {:ok, %List{form | elements: [head, %Identifier{name: name} | rest]},
       [{name, path, dep_ctx}]}
    end
  end

  defp resolve_form(
         %List{elements: [%Identifier{name: :import}, %Identifier{name: mod} | _]} = form,
         ctx
       ) do
    cond do
      MapSet.member?(ctx.unit, mod) ->
        {:ok, form, []}

      entry = Env.get_module(ctx.env, mod) ->
        dep_ctx = %{
          file: entry.path,
          root: entry.root,
          base: ctx.base,
          kind: :module,
          opts: ctx.opts
        }

        {:ok, form, [{mod, entry.path, dep_ctx}]}

      Env.defined?(ctx.env, mod) ->
        {:ok, form, []}

      true ->
        {:error, "módulo desconhecido: #{mod}"}
    end
  end

  defp resolve_form(form, _ctx), do: {:ok, form, []}

  defp resolve_path(rel, %{kind: :module}) do
    {:error, "import por caminho só em arquivo .exls: #{rel}"}
  end

  defp resolve_path(rel, %{kind: :script} = ctx) do
    dir = if ctx.file, do: Path.dirname(ctx.file), else: ctx.base

    path =
      dir
      |> Path.join(rel)
      |> Path.expand()
      |> ensure_extension()

    with {:ok, dep_ctx} <- file_ctx(path, ctx.opts, ctx.base),
         {:ok, name} <- entry_name(dep_ctx) do
      {:ok, name, path, dep_ctx}
    end
  end

  defp script_name(path) do
    base = path |> Path.basename() |> Path.rootname()

    if Regex.match?(@segment, base) do
      {:ok, base |> pascal_case() |> String.to_atom()}
    else
      {:error, "nome de script inválido: #{base}"}
    end
  end

  defp duplicate_plan(plan) do
    plan
    |> Enum.group_by(fn {module, _path} -> module.name end, fn {_module, path} -> path end)
    |> Enum.find(fn {_name, paths} -> length(Enum.uniq(paths)) > 1 end)
    |> case do
      nil -> nil
      {name, paths} -> {name, Enum.uniq(paths)}
    end
  end

  defp ensure_extension(path) do
    if Path.extname(path) == "", do: path <> @extension, else: path
  end

  defp ensure_discovered(nil, env), do: {:ok, env}

  defp ensure_discovered(dir, env) do
    dir = Path.expand(dir)

    cond do
      Env.discovered?(env, dir) ->
        {:ok, env}

      not File.dir?(dir) ->
        {:error, "diretório não encontrado: #{dir}"}

      true ->
        with {:ok, env} <- discover(dir, env) do
          {:ok, Env.mark_discovered(env, dir)}
        end
    end
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join(dir, @root_marker)) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir))
    end
  end

  defp cycle_path(stack, path, ctx) do
    from =
      stack
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 != path))

    (from ++ [path])
    |> Enum.map_join(" -> ", &Path.relative_to(&1, ctx.root || ctx.base))
  end

  # -- Internos

  defp register_file(path, dir, env) do
    with {:ok, file_module} <- derive_name(path, dir),
         {:ok, source} <- File.read(path),
         {:ok, forms} <- parse(source),
         {:ok, modules} <- identify_modules(forms, file_module) do
      Enum.reduce_while(modules, {:ok, env}, fn module, {:ok, env} ->
        case Env.get_module(env, module.name) do
          nil ->
            {:cont, {:ok, Env.put_module(env, module.name, %{path: path, root: dir})}}

          %{path: ^path} ->
            {:cont, {:ok, env}}

          %{path: other} ->
            {:halt, {:error, "módulo #{module.name} definido em #{other} e #{path}"}}
        end
      end)
    end
  end

  defp parse(source) do
    with {:ok, tokens} <- Parser.Lexer.run(source) do
      Parser.SyntaxAnalyzer.run(tokens)
    end
  end

  defp stamp_file(modules, nil), do: modules

  defp stamp_file(modules, path) do
    Enum.map(modules, fn %Module{} = module ->
      %Module{module | meta: Map.put(module.meta, :file, path)}
    end)
  end

  # -- Grafo de dependências

  defp visit_all([], _deps, _states, acc), do: {:ok, acc}

  defp visit_all([name | rest], deps, states, acc) do
    with {:ok, states, emitted} <- visit(name, deps, states, [name]) do
      visit_all(rest, deps, states, acc ++ emitted)
    end
  end

  defp visit(name, deps, states, trail) do
    case states do
      %{^name => :done} ->
        {:ok, states, []}

      %{^name => :loading} ->
        cycle = trail |> Enum.reverse() |> Enum.drop_while(&(&1 != name))
        {:error, "dependência circular: #{Enum.join(cycle, " -> ")}"}

      _ ->
        states = Map.put(states, name, :loading)

        with {:ok, states, emitted} <- visit_deps(deps[name] || [], deps, states, trail) do
          {:ok, Map.put(states, name, :done), emitted ++ [name]}
        end
    end
  end

  defp visit_deps([], _deps, states, _trail), do: {:ok, states, []}

  defp visit_deps([dep | rest], deps, states, trail) do
    with {:ok, states, emitted} <- visit(dep, deps, states, [dep | trail]),
         {:ok, states, more} <- visit_deps(rest, deps, states, trail) do
      {:ok, states, emitted ++ more}
    end
  end

  defp deps_of(%Module{body: body}, by_name) do
    body
    |> Enum.flat_map(&imports_in/1)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(by_name, &1))
  end

  defp imports_in(%List{elements: [%Identifier{name: :import}, %Identifier{name: mod} | _]}),
    do: [mod]

  defp imports_in(_form), do: []

  # -- Identidade

  defp extract_modules(forms, prefix) do
    Enum.reduce(forms, {[], []}, fn
      %List{
        elements: [%Identifier{name: :"def-module"}, %Identifier{name: name} | body],
        meta: meta
      },
      {modules, loose} ->
        full = qualify(name, prefix)
        {nested, own_body} = extract_modules(body, full)
        {modules ++ nested ++ [%Module{name: full, body: own_body, meta: meta}], loose}

      form, {modules, loose} ->
        {modules, loose ++ [form]}
    end)
  end

  defp main_module([], _file_module), do: []

  defp main_module(forms, nil),
    do: [%Module{name: :__main__, body: forms, meta: %{line: 0}}]

  defp main_module(forms, file_module),
    do: [%Module{name: file_module, body: forms, meta: %{line: 0}}]

  defp qualify(name, nil), do: name
  defp qualify(name, prefix), do: :"#{prefix}/#{name}"

  defp duplicate_module(modules) do
    modules
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil -> nil
      {name, _count} -> name
    end
  end

  defp pascal_case(segment) do
    segment
    |> String.split(["_", "-"], trim: true)
    |> Enum.map_join(&String.capitalize/1)
  end
end
