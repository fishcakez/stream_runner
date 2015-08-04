defmodule StreamRunner do
  @moduledoc """
  The `StreamRunner` provides a convenient way to run a `Stream` as process in a
  supervisor tree.

  To run a `Stream` as a process simply pass the stream to `StreamRunner.start_link/1`:

      stream = Stream.interval(1_000) |> Stream.each(&IO.inspect/1)
      {:ok, pid} = StreamRunner.start_link(stream)

  """

  @typedoc "Debug option values."
  @type debug_option :: :trace | :log | :statistics | {:log_to_file, Path.t}

  @typedoc "The name of the `StreamRunner`."
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "`StreamRunner` `start_link/2` or `start/2` option values."
  @type option ::
    {:debug, [debug_option]} |
    {:name, name} |
    {:timeout, timeout} |
    {:spawn_opt, Process.spawn_opt}

  @typedoc "`start_link/2` or `start/2` return values."
  @type on_start :: {:ok, pid} | :ignore | {:error, {:already_started, pid} | term}

  @doc """
  Start a `StreamRunner` as part of the supervision tree.
  """
  @spec start_link(Enumerable.t, [option]) :: on_start
  def start_link(stream, opts \\ []) do
    start(stream, opts, :link)
  end

  @doc """
  Start a `StreamRunner`.

  The `StreamRunner` is not linked to the calling process.
  """
  def start(stream, opts \\ []) do
    start(stream, opts, :nolink)
  end

  ## :gen callbacks

  @doc false
  def init_it(starter, :self, name, mod, stream, opts) do
    init_it(starter, self(), name, mod, stream, opts)
  end
  def init_it(starter, parent, name, __MODULE__, stream, opts) do
    _ = Process.put(:"$initial_call", {StreamRunner, :init_it, 6})
    dbg = :gen.debug_options(opts)
    try do
      Enumerable.reduce(stream, {:suspend, nil}, fn(v, _) -> {:suspend, v} end)
    catch
      :error, value ->
        reason = {value, System.stacktrace()}
        init_error(reason, starter, name)
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        init_error(reason, starter, name)
      :exit, reason ->
        init_error(reason, starter, name)
    else
      {res, nil} when res in [:halted, :done] ->
        init_stop(:ignore, :normal, starter, name)
      {:suspended, nil, cont} ->
        :proc_lib.init_ack(starter, {:ok, self()})
        enter_loop(parent, dbg, name, cont)
      other ->
        reason = {:bad_return_value, other}
        init_error(reason, starter, name)
    end
  end

  ## :sys callbacks

  @doc false
  def system_continue(parent, dbg, [name, cont]) do
    loop(parent, dbg, name, cont)
  end

  @doc false
  def system_terminate(reason, _, _, [name, cont]) do
    terminate(reason, name, cont)
  end

  @doc false
  def system_code_change([name, cont], _, _, _), do: {:ok, [name, cont]}

  @doc false
  def system_get_state([_, cont]), do: {:ok, cont}

  @doc false
  def system_replace_state(replace, [name, cont]) do
    case replace.(cont) do
      cont when is_function(cont, 1) ->
        {:ok, cont, [name, cont]}
     end
  end

  @doc false
  def format_status(:normal, [_, sys_state, parent, dbg, [name, cont]]) do
    header = :gen.format_status_header('Status for StreamRunner', name)
    log = :sys.get_debug(:log, dbg, [])
    [{:header, header},
     {:data, [{'Status', sys_state},
              {'Parent', parent},
              {'Logged Events', log},
              {'Continuation', cont}]}]
  end

  ## Internal

  defp start(stream, opts, link) do
    case Keyword.pop(opts, :name) do
      {nil, opts} ->
        :gen.start(__MODULE__, link, __MODULE__, stream, opts)
      {atom, opts} when is_atom(atom) ->
        :gen.start(__MODULE__, link, {:local, atom}, __MODULE__, stream, opts)
      {{:global, _} = name, opts} ->
        :gen.start(__MODULE__, link, name, __MODULE__, stream, opts)
      {{:via, _, _} = name, opts} ->
        :gen.start(__MODULE__, link, name, __MODULE__, stream, opts)
    end
  end

  defp init_error(reason, starter, name) do
    init_stop({:error, reason}, reason, starter, name)
  end

  defp init_stop(ack, reason, starter, name) do
    _ = unregister(name)
    :proc_lib.init_ack(starter, ack)
    exit(reason)
  end

  defp unregister(pid) when is_pid(pid), do: :ok
  defp unregister({:local, name}) when is_atom(name), do: Process.unregister(name)
  defp unregister({:global, name}), do: :global.unregister_name(name)
  defp unregister({:via, mod, name}), do: apply(mod, :unregister_name, [name])

  defp enter_loop(parent, dbg, {:local, name}, cont) do
    loop(parent, dbg, name, cont)
  end
  defp enter_loop(parent, dbg, name, cont) do
    loop(parent, dbg, name, cont)
  end

  defp loop(parent, dbg, name, cont) do
    receive do
      {:EXIT, ^parent, reason} ->
        terminate(reason, name, cont)
      {:system, from, msg} ->
        :sys.handle_system_msg(msg, from, parent, __MODULE__, dbg, [name, cont])
    after
      0 ->
        try do
          cont.({:cont, nil})
        catch
          :error, value ->
            reason = {value, System.stacktrace()}
            log_stop(reason, reason, name, cont)
          :throw, value ->
            reason = {{:nocatch, value}, System.stacktrace()}
            log_stop(reason, reason, name, cont)
          :exit, value ->
            log_stop({value, System.stacktrace()}, value, name, cont)
        else
          {:suspended, _v, cont} ->
            # todo: log _v and cont with :sys dbg event
            loop(parent, dbg, name, cont)
          {res, nil} when res in [:halted, :done] ->
            exit(:normal)
          other ->
            reason = {:bad_return_value, other}
            terminate(reason, name, cont)
        end
      end
  end

  defp terminate(reason, name, cont) do
    try do
      cont.({:halt, nil})
    catch
      :error, value ->
        reason = {value, System.stacktrace()}
        log_stop(reason, reason, name, cont)
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        log_stop(reason, reason, name, cont)
      :exit, value ->
        log_stop({value, System.stacktrace()}, value, name, cont)
    else
      {res, nil} when res in [:halted, :done] ->
        stop(reason, name, cont)
      other ->
        reason = {:bad_return_value, other}
        log_stop(reason, reason, name, cont)
    end
  end

  defp stop(:normal, _, _),                   do: exit(:normal)
  defp stop(:shutdown, _, _),                 do: exit(:shutdown)
  defp stop({:shutdown, _} = shutdown, _, _), do: exit(shutdown)
  defp stop(reason, name, cont),              do: log_stop(reason, reason, name, cont)

  defp log_stop(report_reason, reason, name, cont) do
    :error_logger.format(
      '** StreamRunner ~p terminating~n' ++
      '** When continuation      == ~p~n' ++
      '** Reason for termination == ~n' ++
      '** ~p~n', [name, cont, format_reason(report_reason)])
    exit(reason)
  end

  defp format_reason({:undef, [{mod, fun, args, _} | _] = stacktrace} = reason)
  when is_atom(mod) and is_atom(fun) do
    cond do
      :code.is_loaded(mod) === false ->
        {:"module could not be loaded", stacktrace}
      is_list(args) and not function_exported?(mod, fun, length(args)) ->
        {:"function not exported", stacktrace}
      is_integer(args) and not function_exported?(mod, fun, args) ->
        {:"function not exported", stacktrace}
      true ->
        reason
    end
  end
  defp format_reason(reason) do
    reason
  end
end
