defmodule Kernel.CLI do
  @moduledoc false

  @compile {:no_warn_undefined, [Logger, IEx]}

  @blank_config %{
    commands: [],
    output: ".",
    compile: [],
    no_halt: false,
    compiler_options: [],
    errors: [],
    verbose_compile: false,
    profile: nil,
    pry: false
  }

  @standalone_opts [~c"-h", ~c"--help", ~c"--short-version"]

  @doc """
  This is the API invoked by Elixir boot process.
  """
  def main(argv) do
    {config, argv} = parse_argv(argv)
    System.argv(Enum.map(argv, &IO.chardata_to_string/1))
    System.no_halt(config.no_halt)

    if config.pry do
      Application.put_env(:elixir, :dbg_callback, {IEx.Pry, :dbg, []})
    end

    fun = fn _ ->
      errors = process_commands(config)

      if errors != [] do
        Enum.each(errors, &IO.puts(:stderr, &1))
        System.halt(1)
      end
    end

    run(fun)
  end

  @doc """
  Runs the given function by catching any failure
  and printing them to stdout. `at_exit` hooks are
  also invoked before exiting.

  This function is used by Elixir's CLI and also
  by escripts generated by Elixir.
  """
  def run(fun) do
    {ok_or_shutdown, status} = exec_fun(fun, {:ok, 0})

    if ok_or_shutdown == :shutdown or not System.no_halt() do
      {_, status} = at_exit({ok_or_shutdown, status})

      # Ensure Logger messages are flushed before halting
      case :erlang.whereis(Logger) do
        pid when is_pid(pid) -> Logger.flush()
        _ -> :ok
      end

      System.halt(status)
    end
  end

  @doc """
  Parses the CLI arguments. Made public for testing.
  """
  def parse_argv(argv) do
    parse_argv(argv, @blank_config)
  end

  @doc """
  Process CLI commands. Made public for testing.
  """
  def process_commands(config) do
    results = Enum.map(Enum.reverse(config.commands), &process_command(&1, config))
    errors = for {:error, msg} <- results, do: msg
    Enum.reverse(config.errors, errors)
  end

  @doc """
  Shared helper for error formatting on CLI tools.
  """
  def format_error(kind, reason, stacktrace) do
    {blamed, stacktrace} = Exception.blame(kind, reason, stacktrace)

    iodata =
      case blamed do
        %FunctionClauseError{} ->
          formatted = Exception.format_banner(kind, reason, stacktrace)
          padded_blame = pad(FunctionClauseError.blame(blamed, &inspect/1, &blame_match/1))
          [formatted, padded_blame]

        _ ->
          Exception.format_banner(kind, blamed, stacktrace)
      end

    [iodata, ?\n, Exception.format_stacktrace(prune_stacktrace(stacktrace))]
  end

  @doc """
  Function invoked across nodes for `--rpc-eval`.
  """
  def rpc_eval(expr) do
    wrapper(fn -> Code.eval_string(expr) end)
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  ## Helpers

  defp at_exit(res) do
    hooks = :elixir_config.get_and_put(:at_exit, [])
    res = Enum.reduce(hooks, res, &exec_fun/2)
    if hooks == [], do: res, else: at_exit(res)
  end

  defp exec_fun(fun, res) when is_function(fun, 1) and is_tuple(res) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        try do
          fun.(elem(res, 1))
        catch
          :exit, {:shutdown, int} when is_integer(int) ->
            send(parent, {self(), {:shutdown, int}})
            exit({:shutdown, int})

          :exit, reason
          when reason == :normal
          when reason == :shutdown
          when tuple_size(reason) == 2 and elem(reason, 0) == :shutdown ->
            send(parent, {self(), {:shutdown, 0}})
            exit(reason)

          kind, reason ->
            print_error(kind, reason, __STACKTRACE__)
            send(parent, {self(), {:shutdown, 1}})
            exit(to_exit(kind, reason, __STACKTRACE__))
        else
          _ ->
            send(parent, {self(), res})
        end
      end)

    receive do
      {^pid, res} ->
        :erlang.demonitor(ref, [:flush])
        res

      {:DOWN, ^ref, _, _, other} ->
        print_error({:EXIT, pid}, other, [])
        {:shutdown, 1}
    end
  end

  defp to_exit(:throw, reason, stack), do: {{:nocatch, reason}, stack}
  defp to_exit(:error, reason, stack), do: {reason, stack}
  defp to_exit(:exit, reason, _stack), do: reason

  defp shared_option?(list, config, callback) do
    case parse_shared(list, config) do
      {[h | hs], _} when h == hd(list) ->
        new_config = %{config | errors: ["#{h} : Unknown option" | config.errors]}
        callback.(hs, new_config)

      {new_list, new_config} ->
        callback.(new_list, new_config)
    end
  end

  ## Error handling

  defp print_error(kind, reason, stacktrace) do
    IO.write(:stderr, format_error(kind, reason, stacktrace))
  end

  defp blame_match(%{match?: true, node: node}), do: blame_ansi(:normal, "+", node)
  defp blame_match(%{match?: false, node: node}), do: blame_ansi(:red, "-", node)

  defp blame_ansi(color, no_ansi, node) do
    if IO.ANSI.enabled?() do
      [color | Macro.to_string(node)]
      |> IO.ANSI.format(true)
      |> IO.iodata_to_binary()
    else
      no_ansi <> Macro.to_string(node) <> no_ansi
    end
  end

  defp pad(string) do
    "    " <> String.replace(string, "\n", "\n    ")
  end

  @elixir_internals [:elixir, :elixir_aliases, :elixir_expand, :elixir_compiler, :elixir_module] ++
                      [:elixir_clauses, :elixir_lexical, :elixir_def, :elixir_map, :elixir_locals] ++
                      [:elixir_erl, :elixir_erl_clauses, :elixir_erl_compiler, :elixir_erl_pass] ++
                      [Kernel.ErrorHandler, Module.ParallelChecker]

  defp prune_stacktrace([{mod, _, _, _} | t]) when mod in @elixir_internals do
    prune_stacktrace(t)
  end

  defp prune_stacktrace([{__MODULE__, :wrapper, 1, _} | _]) do
    []
  end

  defp prune_stacktrace([h | t]) do
    [h | prune_stacktrace(t)]
  end

  defp prune_stacktrace([]) do
    []
  end

  # Parse shared options

  defp halt_standalone(opt) do
    IO.puts(:stderr, "#{opt} : Standalone options can't be combined with other options")
    System.halt(1)
  end

  defp parse_shared([opt | _], _config) when opt in @standalone_opts do
    halt_standalone(opt)
  end

  defp parse_shared([opt | t], _config) when opt in [~c"-v", ~c"--version"] do
    if function_exported?(IEx, :started?, 0) and IEx.started?() do
      IO.puts("IEx " <> System.build_info()[:build])
    else
      IO.puts(:erlang.system_info(:system_version))
      IO.puts("Elixir " <> System.build_info()[:build])
    end

    if t != [] do
      halt_standalone(opt)
    else
      System.halt(0)
    end
  end

  defp parse_shared([~c"-pa", h | t], config) do
    paths = expand_code_path(h)
    Code.prepend_paths(paths)
    parse_shared(t, config)
  end

  defp parse_shared([~c"-pz", h | t], config) do
    paths = expand_code_path(h)
    Code.append_paths(paths)
    parse_shared(t, config)
  end

  defp parse_shared([~c"--app", h | t], config) do
    parse_shared(t, %{config | commands: [{:app, h} | config.commands]})
  end

  defp parse_shared([~c"--no-halt" | t], config) do
    parse_shared(t, %{config | no_halt: true})
  end

  defp parse_shared([~c"-e", h | t], config) do
    parse_shared(t, %{config | commands: [{:eval, h} | config.commands]})
  end

  defp parse_shared([~c"--eval", h | t], config) do
    parse_shared(t, %{config | commands: [{:eval, h} | config.commands]})
  end

  defp parse_shared([~c"--rpc-eval", node, h | t], config) do
    node = append_hostname(node)
    parse_shared(t, %{config | commands: [{:rpc_eval, node, h} | config.commands]})
  end

  defp parse_shared([~c"--rpc-eval" | _], config) do
    new_config = %{config | errors: ["--rpc-eval : wrong number of arguments" | config.errors]}
    {[], new_config}
  end

  defp parse_shared([~c"-r", h | t], config) do
    parse_shared(t, %{config | commands: [{:require, h} | config.commands]})
  end

  defp parse_shared([~c"-pr", h | t], config) do
    parse_shared(t, %{config | commands: [{:parallel_require, h} | config.commands]})
  end

  defp parse_shared(list, config) do
    {list, config}
  end

  defp append_hostname(node) do
    with false <- ?@ in node,
         [_ | _] = suffix <- :string.find(Atom.to_charlist(:net_kernel.nodename()), ~c"@") do
      node ++ suffix
    else
      _ -> node
    end
  end

  defp expand_code_path(path) do
    path = Path.expand(path)

    case Path.wildcard(path) do
      [] -> [to_charlist(path)]
      list -> Enum.map(list, &to_charlist/1)
    end
  end

  # Process init options

  defp parse_argv([~c"--" | t], config) do
    {config, t}
  end

  defp parse_argv([~c"+elixirc" | t], config) do
    parse_compiler(t, config)
  end

  defp parse_argv([~c"+iex" | t], config) do
    parse_iex(t, config)
  end

  defp parse_argv([~c"-S", h | t], config) do
    {%{config | commands: [{:script, h} | config.commands]}, t}
  end

  defp parse_argv([h | t] = list, config) do
    case h do
      [?- | _] ->
        shared_option?(list, config, &parse_argv(&1, &2))

      _ ->
        if List.keymember?(config.commands, :eval, 0) do
          {config, list}
        else
          {%{config | commands: [{:file, h} | config.commands]}, t}
        end
    end
  end

  defp parse_argv([], config) do
    {config, []}
  end

  # Parse compiler options

  defp parse_compiler([~c"--" | t], config) do
    {config, t}
  end

  defp parse_compiler([~c"-o", h | t], config) do
    parse_compiler(t, %{config | output: h})
  end

  defp parse_compiler([~c"--no-docs" | t], config) do
    parse_compiler(t, %{config | compiler_options: [{:docs, false} | config.compiler_options]})
  end

  defp parse_compiler([~c"--no-debug-info" | t], config) do
    compiler_options = [{:debug_info, false} | config.compiler_options]
    parse_compiler(t, %{config | compiler_options: compiler_options})
  end

  defp parse_compiler([~c"--ignore-module-conflict" | t], config) do
    compiler_options = [{:ignore_module_conflict, true} | config.compiler_options]
    parse_compiler(t, %{config | compiler_options: compiler_options})
  end

  defp parse_compiler([~c"--warnings-as-errors" | t], config) do
    compiler_options = [{:warnings_as_errors, true} | config.compiler_options]
    parse_compiler(t, %{config | compiler_options: compiler_options})
  end

  defp parse_compiler([~c"--verbose" | t], config) do
    parse_compiler(t, %{config | verbose_compile: true})
  end

  # Private compiler options

  defp parse_compiler([~c"--profile", "time" | t], config) do
    parse_compiler(t, %{config | profile: :time})
  end

  defp parse_compiler([h | t] = list, config) do
    case h do
      [?- | _] ->
        shared_option?(list, config, &parse_compiler(&1, &2))

      _ ->
        pattern = if File.dir?(h), do: "#{h}/**/*.ex", else: h
        parse_compiler(t, %{config | compile: [pattern | config.compile]})
    end
  end

  defp parse_compiler([], config) do
    {%{config | commands: [{:compile, config.compile} | config.commands]}, []}
  end

  # Parse IEx options

  defp parse_iex([~c"--" | t], config) do
    {config, t}
  end

  defp parse_iex([~c"-S", h | t], config) do
    {%{config | commands: [{:script, h} | config.commands]}, t}
  end

  # These clauses are here so that Kernel.CLI does not error out with "unknown option"
  defp parse_iex([~c"--dbg", backend | t], config) do
    case backend do
      ~c"pry" -> parse_iex(t, %{config | pry: true})
      ~c"kernel" -> parse_iex(t, %{config | pry: false})
      _ -> {:error, "--dbg : Unknown dbg backend #{inspect(backend)}"}
    end
  end

  defp parse_iex([~c"--dot-iex", _ | t], config), do: parse_iex(t, config)
  defp parse_iex([~c"--remsh", _ | t], config), do: parse_iex(t, config)

  defp parse_iex([h | t] = list, config) do
    case h do
      [?- | _] -> shared_option?(list, config, &parse_iex(&1, &2))
      _ -> {%{config | commands: [{:file, h} | config.commands]}, t}
    end
  end

  defp parse_iex([], config) do
    {config, []}
  end

  # Process commands

  defp process_command({:eval, expr}, _config) when is_list(expr) do
    wrapper(fn -> Code.eval_string(expr, []) end)
  end

  defp process_command({:rpc_eval, node, expr}, _config) when is_list(expr) do
    node = List.to_atom(node)

    # Explicitly connect the node in case the rpc node was started with --sname/--name undefined.
    _ = :net_kernel.connect_node(node)

    case :rpc.call(node, __MODULE__, :rpc_eval, [expr]) do
      :ok ->
        :ok

      {:badrpc, {:EXIT, exit}} ->
        Process.exit(self(), exit)

      {:badrpc, reason} ->
        if reason == :nodedown and :net_kernel.nodename() == :ignored do
          {:error,
           "--rpc-eval : Cannot run --rpc-eval if the node is not alive (set --name or --sname)"}
        else
          {:error, "--rpc-eval : RPC failed with reason #{inspect(reason)}"}
        end

      {kind, error, stack} ->
        :erlang.raise(kind, error, stack)
    end
  end

  defp process_command({:app, app}, _config) when is_list(app) do
    case Application.ensure_all_started(List.to_atom(app)) do
      {:error, {app, reason}} ->
        msg = "--app : Could not start application #{app}: " <> Application.format_error(reason)
        {:error, msg}

      {:ok, _} ->
        :ok
    end
  end

  defp process_command({:script, file}, _config) when is_list(file) do
    if exec = find_elixir_executable(file) do
      wrapper(fn -> Code.require_file(IO.chardata_to_string(exec)) end)
    else
      {:error, "-S : Could not find executable #{file}"}
    end
  end

  defp process_command({:file, file}, _config) when is_list(file) do
    if File.regular?(file) do
      wrapper(fn -> Code.require_file(IO.chardata_to_string(file)) end)
    else
      {:error, "No file named #{file}"}
    end
  end

  defp process_command({:require, pattern}, _config) when is_list(pattern) do
    files = filter_patterns(pattern)

    if files != [] do
      wrapper(fn -> Enum.map(files, &Code.require_file/1) end)
    else
      {:error, "-r : No files matched pattern #{pattern}"}
    end
  end

  defp process_command({:parallel_require, pattern}, _config) when is_list(pattern) do
    files = filter_patterns(pattern)

    if files != [] do
      wrapper(fn ->
        case Kernel.ParallelCompiler.require(files) do
          {:ok, _, _} -> :ok
          {:error, _, _} -> exit({:shutdown, 1})
        end
      end)
    else
      {:error, "-pr : No files matched pattern #{pattern}"}
    end
  end

  defp process_command({:compile, patterns}, config) do
    # If ensuring the dir returns an error no files will be found.
    # TODO: Use :filelib.ensure_path/1 once we require Erlang/OTP 25+
    _ = :filelib.ensure_dir(:filename.join(config.output, "."))

    case filter_multiple_patterns(patterns) do
      {:ok, []} ->
        {:error, "No files matched provided patterns"}

      {:ok, files} ->
        wrapper(fn ->
          Code.compiler_options(config.compiler_options)

          verbose_opts =
            if config.verbose_compile do
              [each_file: &IO.puts("Compiling #{Path.relative_to_cwd(&1)}")]
            else
              [
                each_long_compilation:
                  &IO.puts("Compiling #{Path.relative_to_cwd(&1)} (it's taking more than 10s)")
              ]
            end

          profile_opts =
            if config.profile do
              [profile: config.profile]
            else
              []
            end

          output = IO.chardata_to_string(config.output)
          opts = verbose_opts ++ profile_opts

          case Kernel.ParallelCompiler.compile_to_path(files, output, opts) do
            {:ok, _, _} -> :ok
            {:error, _, _} -> exit({:shutdown, 1})
          end
        end)

      {:missing, missing} ->
        {:error, "No files matched pattern(s) #{Enum.join(missing, ",")}"}
    end
  end

  defp filter_patterns(pattern) do
    pattern
    |> Path.expand()
    |> Path.wildcard()
    |> :lists.usort()
    |> Enum.filter(&File.regular?/1)
  end

  defp filter_multiple_patterns(patterns) do
    {files, missing} =
      Enum.reduce(patterns, {[], []}, fn pattern, {files, missing} ->
        case filter_patterns(pattern) do
          [] -> {files, [pattern | missing]}
          match -> {match ++ files, missing}
        end
      end)

    case missing do
      [] -> {:ok, :lists.usort(files)}
      _ -> {:missing, :lists.usort(missing)}
    end
  end

  defp wrapper(fun) do
    _ = fun.()
    :ok
  end

  defp find_elixir_executable(file) do
    if exec = :os.find_executable(file) do
      # If we are on Windows, the executable is going to be
      # a .bat file that must be in the same directory as
      # the actual Elixir executable.
      case :os.type() do
        {:win32, _} ->
          base = :filename.rootname(exec)
          if File.regular?(base), do: base, else: exec

        _ ->
          exec
      end
    end
  end
end
