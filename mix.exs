defmodule Exil.MixProject do
  use Mix.Project

  def project do
    [
      app: :exil,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:junit_formatter, "~> 3.4", only: [:test]}
    ]
  end
end
