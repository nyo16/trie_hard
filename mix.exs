defmodule TrieHard.MixProject do
  use Mix.Project

  @version "0.2.5"
  @source_url "https://github.com/nyo16/trie_hard"

  def project do
    [
      app: :trie_hard,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "TrieHard",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, ">= 0.0.0", optional: true},
      {:rustler_precompiled, "~> 0.8.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A blazing fast, memory-efficient Trie (prefix tree) implementation for Elixir
    with autocomplete support, powered by a high-performance Rust NIF.
    """
  end

  defp package do
    [
      name: "trie_hard",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md checksum-*.exs),
      licenses: ["Apache-2.0"],
      links: %{
        GitHub: @source_url,
        Changelog: "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Niko"]
    ]
  end

  defp docs do
    [
      main: "TrieHard",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
