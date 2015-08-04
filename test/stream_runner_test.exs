defmodule StreamRunnerTest do
  use ExUnit.Case, async: false

  setup_all do
    {:ok, apps} = Application.ensure_all_started(:logger)
    Logger.remove_backend(:console, [flush: true])
    if :logger in apps do
      on_exit(&Logger.App.stop/0)
      apps = Enum.filter(apps, &(&1 != :logger))
      on_exit(fn() -> Enum.each(apps, &Application.stop/1) end)
    else
      on_exit(fn() -> Logger.add_backend(:console, [flush: true]) end)
    end
  end

  test "start_link/1" do
    {:ok, pid} = StreamRunner.start_link(interval_stream())
    assert :proc_lib.translate_initial_call(pid) == {StreamRunner, :init_it, 6}
    caller = self()
    assert Process.info(pid, :links) == {:links, [caller]}
    assert_receive 0
    assert_receive 1
    assert_receive 2
  end

  test "start_link/2 :local name" do
    {:ok, pid} = StreamRunner.start_link(interval_stream(), [name: __MODULE__])
    assert Process.whereis(__MODULE__) == pid
    assert_receive 0
  end

  test "start_link/2 :global name" do
    {:ok, pid} = StreamRunner.start_link(interval_stream(), [name: {:global, {__MODULE__, :global}}])
    assert :global.whereis_name({__MODULE__, :global}) == pid
    assert_receive 0
  end

  test "start_link/2 :via name" do
    {:ok, pid} = StreamRunner.start_link(interval_stream(), [name: {:via, :global, {__MODULE__, :via}}])
    assert :global.whereis_name({__MODULE__, :via}) == pid
    assert_receive 0
  end


  test "start/1" do
    {:ok, pid} = StreamRunner.start(interval_stream())
    assert Process.info(pid, :links) == {:links, []}
    Process.link(pid)
    assert_receive 0
    assert_receive 1
    assert_receive 2
  end

  test "exit normally on :halt" do
    Process.flag(:trap_exit, true)
    caller = self()
    start_fun = fn() -> send(caller, :start) ; nil end
    next_fun = fn(acc) -> send(caller, :next) ; {:halt, acc} end
    after_fun = fn(_) -> send(caller, :after) end
    stream = Stream.resource(start_fun, next_fun, after_fun)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive :start
    assert_receive :next
    assert_receive {:EXIT, ^pid, :normal}
    assert_received :after
    refute_received :after
  end

  test "exit normally on :done" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = StreamRunner.start_link([])
    assert_receive {:EXIT, ^pid, :normal}
  end

  @tag :raise
  test "start throw with :local name" do
    stream = start_stream(fn() -> throw(:oops) end)
    assert {:error, {{:nocatch, :oops}, [_|_]}} = StreamRunner.start(stream, [name: :oops])
    assert Process.whereis(:oops) == nil
    refute_received :next
  end

  @tag :raise
  test "start exit with :global name" do
    stream = start_stream(fn() -> exit(:oops) end)
    assert {:error, :oops} = StreamRunner.start(stream, [name: {:global, :oops}])
    assert :global.whereis_name(:oops) == :undefined
    refute_received :next
  end

  @tag :raise
  test "start error with :via name" do
    stream = start_stream(fn() -> raise "oops" end)
    assert {:error, {%RuntimeError{}, [_|_]}} = StreamRunner.start(stream, [name: {:via, :global,:oops}])
    assert :global.whereis_name(:oops) == :undefined
    refute_received :next
  end

  @tag :raise
  test "next throw" do
    Process.flag(:trap_exit, true)
    stream = next_stream(fn() -> throw(:oops) end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, {{:nocatch, :oops}, [_|_]}}
    assert_received :after
    refute_received :after
  end

  @tag :raise
  test "next exit" do
    Process.flag(:trap_exit, true)
    stream = next_stream(fn() -> exit(:oops) end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, :oops}
    assert_received :after
    refute_received :after
  end

  @tag :raise
  test "next error" do
    Process.flag(:trap_exit, true)
    stream = next_stream(fn() -> raise ":oops" end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, {%RuntimeError{}, [_|_]}}
    assert_received :after
    refute_received :after
  end

  @tag :raise
  test "after throw" do
    Process.flag(:trap_exit, true)
    stream = after_stream(fn() -> throw(:oops) end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, {{:nocatch, :oops}, [_|_]}}
    assert_received :after
    refute_received :after
  end

  @tag :raise
  test "after exit" do
    Process.flag(:trap_exit, true)
    stream = after_stream(fn() -> exit(:oops) end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, :oops}
    assert_received :after
    refute_received :after
  end

  @tag :raise
  test "after error" do
    Process.flag(:trap_exit, true)
    stream = after_stream(fn() -> raise ":oops" end)
    {:ok, pid} = StreamRunner.start_link(stream)
    assert_receive {:EXIT, ^pid, {%RuntimeError{}, [_|_]}}
    assert_received :after
    refute_received :after
  end

  @tag :sys
  test ":sys.get_state/1" do
    {:ok, pid} = StreamRunner.start_link(interval_stream())
    assert_receive 0
    assert is_function(:sys.get_state(pid), 1)
    assert_receive 1
  end

  @tag :sys
  test ":sys.replace_state/2" do
    {:ok, pid} = StreamRunner.start_link(interval_stream())
    assert_receive 0
    mon = Process.monitor(pid)
    cont = fn(_) -> {:done, nil} end
    assert is_function(:sys.replace_state(pid, fn(_) -> cont end))
    assert_receive {:DOWN, ^mon, _, _, :normal}
  end

  @tag :sys
  test ":sys.statistics/2" do
    {:ok, pid} = StreamRunner.start_link(interval_stream(), [debug: [:statistics]])
    assert_receive 0
    {:ok, stats} = :sys.statistics(pid, :get)
    reductions = Keyword.fetch!(stats, :reductions)
    {:ok, stats} = :sys.statistics(pid, :get)
    assert Keyword.fetch!(stats, :reductions) > reductions
    assert :sys.statistics(pid, :false) == :ok
    assert :sys.statistics(pid, :get) == {:ok, :no_statistics}
    assert_receive 1
  end

  @tag :sys
  test ":sys.get_status/1" do
    {:ok, pid} = StreamRunner.start_link(interval_stream())
    assert_receive 0
    assert {:status, ^pid, {:module, StreamRunner}, info} = :sys.get_status(pid)
    caller = self()
    assert [pdict, :running, ^caller, [], status] = info
    assert Keyword.get(pdict, :"$initial_call") == {StreamRunner, :init_it, 6}
    assert {:ok, 'Status for StreamRunner <' ++ _} = Keyword.fetch(status, :header)
    assert {:ok, [{'Status', :running},
                  {'Parent', ^caller},
                  {'Logged Events', []},
                  {'Continuation', cont}]} = Keyword.fetch(status, :data)
    assert is_function(cont, 1)
  end

  @tag :sys
  test ":sys.change_code/4" do
    {:ok, pid} = StreamRunner.start_link(interval_stream())
    assert_receive 0
    assert :sys.suspend(pid) == :ok
    assert :sys.change_code(pid, __MODULE__, nil, nil) == :ok
    assert :sys.resume(pid) == :ok
    assert_receive 2, 200
  end

  @tag :sys
  test ":sys.terminate/2 normal" do
    if function_exported?(:sys, :terminate, 2) do
      caller = self()
      start_fun = fn() -> send(caller, :start) ; nil end
      next_fun = fn(acc) -> {[1], acc} end
      after_fun = fn(_) -> send(caller, :after) end
      stream = Stream.resource(start_fun, next_fun, after_fun)
      {:ok, pid} = StreamRunner.start_link(stream)
      assert_receive :start
      mon = Process.monitor(pid)
      assert :sys.terminate(pid, :normal) == :ok
      assert_receive {:DOWN, ^mon, _, _, :normal}
      assert_received :after
    end
  end

  @tag :sys
  test ":sys.handle_debug/4" do
    {:ok, pid} = StreamRunner.start_link(Stream.interval(50))
    hook = fn(caller, event, name) -> send(caller, {name, event}) ; caller end
    assert :sys.install(pid, {hook, self()}) == :ok
    assert_receive {^pid, {:suspended, 1, cont}} when is_function(cont, 1)
    assert_receive {^pid, {:suspended, 2, cont}} when is_function(cont, 1)
  end

  ## Helpers

  defp interval_stream() do
    caller = self()
    Stream.interval(50) |> Stream.map(&send(caller, &1))
  end

  defp start_stream(start_fun) do
    caller = self()
    next_fun = fn(acc) -> send(caller, :next) ; {[1], acc} end
    after_fun = fn(_) -> :ok end
    Stream.resource(start_fun, next_fun, after_fun)
  end

  defp next_stream(next_fun) do
    caller = self()
    start_fun = fn() -> nil end
    next_fun = fn(_) -> next_fun.() end
    after_fun = fn(_) -> send(caller, :after) end
    Stream.resource(start_fun, next_fun, after_fun)
  end

  defp after_stream(after_fun) do
    caller = self()
    start_fun = fn() -> nil end
    next_fun = fn(acc) -> {:done, acc} end
    after_fun = fn(_) -> send(caller, :after) ; after_fun.() end
    Stream.resource(start_fun, next_fun, after_fun)
  end
end
