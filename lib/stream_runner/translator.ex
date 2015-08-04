defmodule StreamRunner.Translator do
  @moduledoc """
  A Logger translator for `StreamRunner` error messages.
  """

  @doc """
  Translate `StreamRunner` error messages.

  To add the translator to Logger:

      Logger.add_translator({StreamRunner.Translator, :translate})

  """
  def translate(min_level, :error, :format, {'** StreamRunner ' ++ _, [name, cont, reason]}) do
    msg = ["StreamRunner ", inspect(name), " terminating" | format_stop(reason)]
    if min_level == :debug do
      msg = [msg, "\nContinuation: " | inspect(cont)]
    end
    {:ok, msg}
  end
  def translate(_, _, _, _) do
    :none
  end

  ## Helpers from Elixir's Logger.Translator

  defp format_stop({maybe_exception, [_ | _ ] = maybe_stacktrace} = reason) do
    try do
      format_stacktrace(maybe_stacktrace)
    catch
      :error, _ ->
        format_stop_banner(reason)
    else
      formatted_stacktrace ->
        [format_stop_banner(maybe_exception, maybe_stacktrace) |
          formatted_stacktrace]
    end
  end

  defp format_stop(reason) do
    format_stop_banner(reason)
  end

  defp format_stop_banner(reason) do
    ["\n** (stop) " | Exception.format_exit(reason)]
  end

  # OTP process rewrite the :undef error to these reasons when logging
  @gen_undef [:"module could not be loaded", :"function not exported"]

  defp format_stop_banner(undef, [{mod, fun, args, _info} | _ ]  = stacktrace)
  when undef in @gen_undef and is_atom(mod) and is_atom(fun) do
    cond do
      is_list(args) ->
        format_undef(mod, fun, length(args), undef, stacktrace)
      is_integer(args) ->
        format_undef(mod, fun, args, undef, stacktrace)
      true ->
        format_stop_banner(undef)
    end
  end

  defp format_stop_banner(reason, stacktrace) do
    if Exception.exception?(reason) do
        [?\n | Exception.format_banner(:error, reason, stacktrace)]
    else
      case Exception.normalize(:error, reason, stacktrace) do
        %ErlangError{} ->
          format_stop_banner(reason)
        exception ->
          [?\n | Exception.format_banner(:error, exception, stacktrace)]
      end
    end
  end

  defp format_undef(mod, fun, arity, undef, stacktrace) do
    opts = [module: mod, function: fun, arity: arity, reason: undef]
    exception = UndefinedFunctionError.exception(opts)
    [?\n | Exception.format_banner(:error, exception, stacktrace)]
  end

  defp format_stacktrace(stacktrace) do
      for entry <- stacktrace do
        [<<"\n    ">> | Exception.format_stacktrace_entry(entry)]
      end
  end
end
