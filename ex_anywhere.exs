#! /usr/bin/env elixir

defmodule ExAnywhere do
  import Access
  @mix_project_dir (System.get_env("HOME") || "c:") <> "/.ex_anywhere/ex_anywhere"
  @mix_file @mix_project_dir <> "/mix.exs"

  def main do
    args = System.argv()
    ensure_mix_project()

    cond do
      repl?() ->
        # let iex import module
        spawn(fn ->
          :timer.sleep(100)

          {ev, server} =
            evaluator()
            |> case do
              nil ->
                # on windows it returns nil, but we can enum all process to find the evaluator
                Process.list()
                |> Enum.filter(fn pid ->
                  {IEx.Evaluator, :init, 4} == Process.info(pid)[:dictionary][:"$initial_call"]
                end)
                |> case do
                  [ev | _] ->
                    [server] = Process.info(ev)[:dictionary][:"$ancestors"]
                    {ev, server}

                  [] ->
                    nil
                end

              value ->
                value
            end

          send(ev, {:eval, server, "import ExAnywhere.Helper; :ok", %IEx.State{prefix: "iex"}})
        end)

      args in [[], ["-h"], ["--help"]] ->
        # show help
        IO.puts("
Usage: iex -S exa
  or:  exa FILE [ARGUMENTS]
")

      true ->
        [file | args] = args
        System.argv(args)

        {quoted, deps} =
          file
          |> File.read!()
          |> Code.string_to_quoted!()
          |> Macro.postwalk([], fn
            {:deps, _, dep}, deps -> {[], deps ++ List.wrap(dep)}
            ast, deps -> {ast, deps}
          end)

        load_deps(deps)
        Code.eval_quoted(quoted, [], file: file)
    end
  end

  def evaluator do
    Version.compare(System.version(), "1.8.0")
    |> case do
      :lt -> IEx.Server.evaluator()
      _ -> IEx.Broker.evaluator()
    end
  end

  def repl?() do
    IEx.started?()
  end

  def success_cmd!({result, 0}, _), do: result

  def success_cmd!({_, code}, cmd) do
    raise RuntimeError, message: "`mix #{cmd |> Enum.join(" ")}` failed with code: #{code}"
  end

  def mix_cmd(cmd, opt \\ []) do
    opt =
      if repl?() && !opt[:into] do
        [into: IO.stream(:stdio, :line)] ++ opt
      else
        opt
      end

    opt =
      if opt[:cd] do
        opt
      else
        [cd: @mix_project_dir] ++ opt
      end

    System.cmd("mix", cmd, opt)
  end

  def mix_cmd!(cmd, opt \\ []) do
    mix_cmd(cmd, opt)
    |> success_cmd!(cmd)
  end

  def ensure_mix_project do
    unless File.exists?(@mix_file) do
      parent_dir = @mix_project_dir |> Path.dirname()
      File.mkdir_p!(parent_dir)
      mix_cmd(~w{local.hex --if-missing --force}, cd: parent_dir)
      mix_cmd(~w{local.rebar --if-missing --force}, cd: parent_dir)
      mix_cmd!(~w{new ex_anywhere}, cd: parent_dir)
    end
  end

  def expand_deps(deps) do
    tree = deps_tree()

    Enum.flat_map(deps, fn dep ->
      name = dep_name(dep)

      if tree = tree[name] do
        list =
          tree
          |> Macro.postwalk([], fn
            {name, _} = ast, acc when is_atom(name) -> {ast, [name | acc]}
            ast, acc -> {ast, acc}
          end)
          |> elem(1)

        [name | list]
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  def loaded?(dep) do
    dir = ebin_dir(dep) |> String.to_charlist()
    dir in :code.get_path()
  end

  def load(dep) do
    dir = ebin_dir(dep)

    unless File.exists?(dir) do
      deps_get_and_compile()
    end

    unless loaded?(dep) do
      dir |> String.to_charlist() |> :code.add_path()
    end
  end

  def load_deps(deps) do
    Enum.reject(deps, &loaded?/1)
    |> case do
      [] ->
        :ok

      deps ->
        ensure_deps(deps)
        expand_deps(deps) |> Enum.each(&load/1)
        deps |> Enum.map(&dep_name/1) |> Enum.each(&Application.ensure_all_started/1)
    end
  end

  def load_dep(dep), do: load_deps([dep])

  def deps_tree do
    mix_cmd!(~w{deps.tree --format plain}, into: "")
    |> parse_deps_tree()
  end

  def parse_deps_tree(output) do
    output
    |> String.split("\n", trim: true)
    |> tl
    |> Enum.map(&deps_tree_level/1)
    |> build_deps_tree(1)
    |> elem(0)
  end

  def deps_tree_level(line), do: deps_tree_level(line, 0)
  def deps_tree_level("|-- " <> line, level), do: deps_tree_level(line, level + 1)
  def deps_tree_level("|   " <> line, level), do: deps_tree_level(line, level + 1)
  def deps_tree_level("`-- " <> line, level), do: deps_tree_level(line, level + 1)
  def deps_tree_level("    " <> line, level), do: deps_tree_level(line, level + 1)

  def deps_tree_level(line, level),
    do: {level, String.split(line, " ", parts: 2) |> hd |> String.to_atom()}

  def build_deps_tree([{level, name} | next], level) do
    {childs, next} = build_deps_tree(next, level + 1)
    {next_deps, next} = build_deps_tree(next, level)
    {[{name, childs} | next_deps], next}
  end

  def build_deps_tree(others, _level), do: {[], others}

  def dep_name(atom) when is_atom(atom), do: atom
  def dep_name({atom, _}) when is_atom(atom), do: atom
  def dep_name({atom, _, _}) when is_atom(atom), do: atom

  def ebin_dir(dep) do
    "#{@mix_project_dir}/_build/dev/lib/#{dep_name(dep)}/ebin"
  end

  def ensure_deps(deps) do
    exist_deps = current_deps() |> Enum.map(&dep_name/1) |> MapSet.new()

    deps
    |> Enum.reject(fn dep ->
      dep_name(dep) in exist_deps
    end)
    |> Enum.map(fn
      # support deps only name
      name when is_atom(name) -> {name, ">=0.0.0"}
      other -> other
    end)
    |> case do
      [] ->
        :ok

      adds ->
        # add deps to mix.exs
        mix_ast(fn ast ->
          Macro.prewalk(ast, fn
            {:defp, _, [{:deps, _, _}, [{:do, _}]]} = ast ->
              update_in(ast, [elem(2), at(1), at(0), elem(1)], &(&1 ++ adds))

            other ->
              other
          end)
        end)

        deps_get_and_compile()
    end
  end

  def deps_get_and_compile() do
    mix_cmd!(~w{do deps.get, deps.compile})
  end

  def mix_ast(update \\ nil) do
    ast =
      @mix_file
      |> File.read!()
      |> Code.string_to_quoted!()

    if update do
      ast = update.(ast)
      code = Macro.to_string(ast)
      File.write!(@mix_file, code)
      ast
    else
      ast
    end
  end

  def current_deps() do
    deps_ast =
      mix_ast()
      |> find_ast(fn
        ast -> match?({:defp, _, [{:deps, _, _}, _]}, ast)
      end)
      |> elem(1)

    {:defp, _, [{:deps, _, _}, [{:do, deps_ast}]]} = deps_ast
    deps_ast
  end

  def find_ast(ast, fun) do
    Macro.prewalk(ast, nil, fn
      x, a ->
        if a == nil and fun.(x) do
          {x, x}
        else
          {x, a}
        end
    end)
  end
end

defmodule ExAnywhere.Helper do
  def deps(dep) do
    ExAnywhere.load_deps(List.wrap(dep))
  end
end

ExAnywhere.main()
:ok
