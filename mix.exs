defmodule StreamRunner.Mixfile do
  use Mix.Project

  @version "1.0.2"

  def project do
    [app: :stream_runner,
     version: @version,
     elixir: "~> 1.0",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps,
     description: description,
     package: package,
     docs: docs]
  end

  def application do
    [applications: []]
  end

  defp deps do
    [{:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.7", only: :dev}]
  end

  defp docs do
    [source_url: "https://github.com/fishcakez/stream_runner",
     source_ref: "v#{@version}",
     main: StreamRunner]
  end

  defp description do
    """
    Run a Stream as a process
    """
  end

  defp package do
    %{licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/fishcakez/stream_runner"}}
  end
end
