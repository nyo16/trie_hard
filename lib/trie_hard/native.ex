defmodule TrieHard.Native do
  @moduledoc false

  mix_config = Mix.Project.config()
  version = mix_config[:version]
  github_url = mix_config[:package][:links][:GitHub]
  mode = if Mix.env() in [:dev, :test], do: :debug, else: :release

  use RustlerPrecompiled,
    otp_app: :trie_hard,
    crate: "trie_hard_native",
    version: version,
    base_url: "#{github_url}/releases/download/v#{version}",
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl

      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl

      x86_64-pc-windows-gnu
    ),
    nif_versions: ["2.16", "2.17"],
    mode: mode,
    force_build: System.get_env("TRIE_HARD_BUILD") in ["1", "true"]

  # Placeholder functions that will be replaced by NIF implementations.
  # Fast NIFs return :dirty when the lock is contended or the work exceeds the
  # normal-scheduler budget; the caller retries with the *_dirty twin.
  def new_trie, do: :erlang.nif_error(:nif_not_loaded)
  def insert(_trie, _key, _etf), do: :erlang.nif_error(:nif_not_loaded)
  def insert_dirty(_trie, _key, _etf), do: :erlang.nif_error(:nif_not_loaded)
  def get(_trie, _key), do: :erlang.nif_error(:nif_not_loaded)
  def get_dirty(_trie, _key), do: :erlang.nif_error(:nif_not_loaded)
  def delete(_trie, _key), do: :erlang.nif_error(:nif_not_loaded)
  def delete_dirty(_trie, _key), do: :erlang.nif_error(:nif_not_loaded)
  def prefix_search(_trie, _prefix), do: :erlang.nif_error(:nif_not_loaded)
  def prefix_search_dirty(_trie, _prefix), do: :erlang.nif_error(:nif_not_loaded)
  def auto_complete(_trie, _prefix, _max_results), do: :erlang.nif_error(:nif_not_loaded)
  def auto_complete_dirty(_trie, _prefix, _max_results), do: :erlang.nif_error(:nif_not_loaded)
  def count_prefix(_trie, _prefix), do: :erlang.nif_error(:nif_not_loaded)
  def count_prefix_dirty(_trie, _prefix), do: :erlang.nif_error(:nif_not_loaded)
  def add_word_list(_trie, _words), do: :erlang.nif_error(:nif_not_loaded)
end
