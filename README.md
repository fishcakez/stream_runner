StreamRunner
============

Proof of concept to run a `Stream` as an OTP process.
```elixir
stream = Stream.interval(1000) |> Stream.each(&IO.inspect/1)
StreamRunner.start_link(stream)
```
