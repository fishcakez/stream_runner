defmodule StreamRunner do

  def start_link(stream, opts \\ []) do
    start(stream, opts, :link)
  end

  def start(stream, opts \\ []) do
    start(stream, opts, :nolink)
  end

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

  ## :gen callbacks

  def init_it(starter, :self, name, mod, stream, opts) do
    init_it(starter, self(), name, mod, stream, opts)
  end
  def init_it(starter, parent, name, __MODULE__, stream, opts) do
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

  def system_continue(parent, dbg, [name, cont]) do
    loop(parent, dbg, name, cont)
  end

  def system_stop(reason, _, _, [name, cont]) do
    terminate(reason, name, cont)
  end

  def system_code_change([name, cont], _, _, _), do: {:ok, [name, cont]}

  def system_get_state([_, cont]), do: {:ok, cont}

  def system_replace_state(replace, [name, cont]) do
    case replace.(cont) do
      cont when is_function(cont, 1) ->
        {:ok, cont, [name, cont]}
     end
  end

  def format_status(:normal, [_, sys_state, parent, dbg, [name, cont]]) do
    header = :gen.format_status_header('Status for Streamer', name)
    log = :sys.get_debug(:log, dbg, [])
    [{:header, header},
     {:data, [{'Status', sys_state},
              {'Parent', parent},
              {'Logged Events', log},
              {'Continuation', cont}]}]
  end

  ## Internal

  defp init_error(reason, starter, name) do
    init_stop({:error, reason}, reason, starter, name)
  end

  defp init_stop(ack, reason, starter, name) do
    _ = unregister(name)
    :proc_lib.init_ack(starter, ack)
    exit(reason)
  end

  defp unregister(pid) when is_pid(pid), do: :ok
  defp unregister(name) when is_atom(name), do: Process.unregister(name)
  defp unregister({:global, name}), do: :global.unregister_name(name)
  defp unregister({:via, mod, name}), do: apply(mod, :unregister_name, [name])

  defp enter_loop(parent, dbg, {:local, name}, cont) do
    loop(parent, dbg, name, cont)
  end
  defp enter_loop(parent, dbg, name, cont) do
    loop(parent, dbg, name, cont)
  end

  defp loop(parent, dbg, name, cont) do
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
        receive do
          {:EXIT, ^parent, reason} ->
            terminate(reason, name, cont)
          {:system, from, msg} ->
            :sys.handle_system_msg(msg, from, parent, __MODULE__, dbg, [name, cont])
        after
          0 ->
            loop(parent, dbg, name, cont)
      end
      {res, nil} when res in [:halted, :done] ->
        terminate(:normal, name, cont)
      other ->
        reason = {:bad_return_value, other}
        terminate(reason, name, cont)
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

  defp log_stop(reason, report_reason, name, cont) do
    :error_logger.format(
      '** StreamRunner ~p terminating~n' ++
      '** When continuation      == ~p~n' ++
      '** Reason for termination == ~n' ++
      '** ~p~n', [name, cont, report_reason])
    exit(reason)
  end
end
