defmodule Mix.Tasks.Desktop.Stage do
  @shortdoc "Builds the production release and stages it for the Tauri bundle"

  @moduledoc """
  Prepares everything the desktop app needs from the Elixir side:

      mix desktop.stage

  Fetches the portable QEMU if `qemu/` has none (`mix qemu.fetch`), digests
  the assets, builds the `:prod` release with ERTS and QEMU inside it, and
  copies the result to `src-tauri/resources/rel`, which is where both the
  bundler and `cargo run` look for it.

  It stages a *copy* rather than pointing Tauri at `_build`. The bundler
  walks the resource directory at build time, and `_build/prod/rel` is also
  where `mix release` writes — having it read a tree that a concurrent
  rebuild is rewriting is the kind of failure that only shows up in the
  installer.
  """

  use Mix.Task

  @release_path "_build/prod/rel/qemu_admin"
  @staging_path "src-tauri/resources/rel"
  @stamp_path "src-tauri/resources/staged_at"

  @impl Mix.Task
  def run(args) do
    unless Mix.env() == :prod do
      Mix.raise("mix desktop.stage must run in :prod — use MIX_ENV=prod mix desktop.stage")
    end

    # The portable QEMU the release carries (`qemu/`, copied in by the
    # release step in mix.exs); a no-op when it is already there.
    Mix.Task.run("qemu.fetch", [])
    Mix.Task.run("assets.deploy", [])
    Mix.Task.run("release", ["--overwrite" | args])

    stage()
  end

  defp stage do
    File.rm_rf!(@staging_path)
    File.mkdir_p!(Path.dirname(@staging_path))

    case File.cp_r(@release_path, @staging_path) do
      {:ok, _files} ->
        stamp()
        Mix.shell().info([:green, "* staged ", :reset, @staging_path, " (", size(), ")"])

      {:error, reason, file} ->
        Mix.raise("failed to stage the release: #{:file.format_error(reason)} on #{file}")
    end
  end

  # `src-tauri/build.rs` compares this file's mtime against the Elixir
  # sources and fails the Rust build when it is older. Without it, editing
  # Elixir and running only `cargo tauri build` produces an installer that
  # silently carries the previous release — the copy step reads
  # `resources/` and never looks at `lib/`.
  defp stamp do
    File.write!(@stamp_path, "#{DateTime.utc_now()}\n")
  end

  defp size do
    bytes =
      @staging_path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reduce(0, fn path, total ->
        case File.stat(path) do
          {:ok, %{type: :regular, size: size}} -> total + size
          _ -> total
        end
      end)

    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end
end
