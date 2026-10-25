defmodule Mix.Tasks.Desktop.Build do
  @shortdoc "Builds the desktop installer, from Elixir release to bundle"

  @moduledoc """
  The whole desktop build in one command:

      mix desktop.build

  It runs `desktop.stage` and then the Tauri bundler, so there is no order
  to remember and no `MIX_ENV` to set — the staging step is spawned as its
  own `MIX_ENV=prod` run, which is why this task itself can be invoked from
  any environment.

  Extra arguments go to the Tauri CLI:

      mix desktop.build --debug

  Expect several minutes on a cold build: the release profile uses LTO with
  a single codegen unit, and the bundler downloads NSIS and the WebView2
  runtime the first time.

  ## The Tauri CLI

  Invoked through `npx`, which fetches a prebuilt binary, rather than
  `cargo install tauri-cli`, which compiles it from source for several
  minutes. Set `TAURI_CLI` to override — `cargo tauri`, for instance, if
  you have installed it:

      TAURI_CLI="cargo tauri" mix desktop.build
  """

  use Mix.Task

  @tauri_dir "src-tauri"
  @default_cli ~w(npx --yes @tauri-apps/cli@^2)
  @bundle_dir "src-tauri/target/release/bundle"

  @impl Mix.Task
  def run(args) do
    stage()
    bundle(args)
    report()
  end

  defp stage do
    Mix.shell().info([:cyan, "==> montando a release Elixir", :reset])

    # A separate run rather than `Mix.Task.run/2`: the release has to be
    # built in :prod, and an already-booted Mix cannot change its own env.
    cmd("mix", ["desktop.stage"], env: [{"MIX_ENV", "prod"}])
  end

  defp bundle(args) do
    Mix.shell().info([:cyan, "\n==> empacotando com o Tauri", :reset])

    [program | leading] = tauri_cli()
    cmd(program, leading ++ ["build" | args], cd: @tauri_dir, env: cargo_env())
  end

  # The bundler shells out to `cargo`, and a rustup installed by a package
  # manager often exports CARGO_HOME without putting its bin directory on
  # PATH. Falling back to CARGO_HOME — Cargo's own variable — beats letting
  # the Tauri CLI fail several steps later with "program not found".
  defp cargo_env do
    cond do
      System.find_executable("cargo") -> []
      dir = cargo_bin() -> [{"PATH", dir <> path_separator() <> System.get_env("PATH", "")}]
      true -> Mix.raise(cargo_missing())
    end
  end

  defp cargo_bin do
    home = System.user_home()

    [System.get_env("CARGO_HOME"), home && Path.join(home, ".cargo")]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, "bin"))
    |> Enum.find(&File.exists?(Path.join(&1, cargo_exe())))
  end

  defp cargo_exe, do: if(match?({:win32, _}, :os.type()), do: "cargo.exe", else: "cargo")

  defp path_separator, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  defp cargo_missing do
    """
    cargo não foi encontrado.

    O bundler do Tauri compila um binário Rust, então é preciso ter o
    toolchain instalado (https://rustup.rs) e no PATH — ou a variável
    CARGO_HOME apontando para a instalação.
    """
  end

  defp tauri_cli do
    case System.get_env("TAURI_CLI") do
      nil -> @default_cli
      "" -> @default_cli
      override -> String.split(override, " ", trim: true)
    end
  end

  defp report do
    installers =
      @bundle_dir
      |> Path.join("*/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    case installers do
      [] ->
        Mix.shell().info([:yellow, "\n* nenhum instalador encontrado em ", @bundle_dir, :reset])

      paths ->
        Mix.shell().info([:green, "\n* pronto", :reset])

        for path <- paths do
          Mix.shell().info(["  ", path, " (", size(path), ")"])
        end
    end
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      _ -> "?"
    end
  end

  defp cmd(program, args, opts) do
    {program, args} = through_shell(program, args)

    opts =
      opts
      |> Keyword.put(:into, IO.binstream())
      |> Keyword.put(:stderr_to_stdout, true)

    case System.cmd(program, args, opts) do
      {_output, 0} ->
        :ok

      {_output, status} ->
        Mix.raise("#{program} #{Enum.join(args, " ")} falhou com status #{status}")
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> Mix.raise("#{program} não foi encontrado no PATH")
        _ -> reraise(error, __STACKTRACE__)
      end
  end

  # `mix` and `npx` are batch files on Windows, and the VM can only spawn
  # real executables — they have to go through cmd.
  defp through_shell(program, args) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", program | args]}
      _ -> {program, args}
    end
  end
end
