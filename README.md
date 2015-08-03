StreamRunner
============

Install
-------
Add as a dependency:
```elixir
defp deps() do
  [{:stream_runner, "~> 1.0"}]
end
```

Usage
-----
Run a `Stream` as an OTP process.
```elixir
stream = Stream.interval(1000) |> Stream.each(&IO.inspect/1)
StreamRunner.start_link(stream)
```
