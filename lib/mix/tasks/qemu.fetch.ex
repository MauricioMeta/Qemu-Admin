defmodule Mix.Tasks.Qemu.Fetch do
  @shortdoc "Downloads the portable QEMU that the app (and its release) ships with"

  @moduledoc """
  Puts a portable QEMU in `qemu/` at the project root:

      mix qemu.fetch
      mix qemu.fetch --targets x86_64,aarch64
      mix qemu.fetch --force
      mix qemu.fetch --no-esp

  The newest Windows build from qemu.weilnetz.de (the one qemu.org links),
  checked against its SHA-512 and unpacked with 7-Zip — see
  `QemuAdmin.Qemu.Installer`. The installer is kept in `.cache/`, so running
  it again (other targets, say) does not download it again.

  `mix phx.server` finds `qemu/` by itself, and `mix release` copies it into
  the release (`mix.exs`), which is how the Tauri bundle becomes
  self-contained. Only the emulators of `--targets` are kept (default in
  `config :qemu_admin, :qemu_fetch`).

  Then Espressif's QEMU (the ESP32 emulator, `QemuAdmin.Qemu.Esp`) into
  `qemu-esp/` — on any OS, since Espressif builds it for Linux and macOS
  too; `--no-esp` skips it.

  Skips a download when its folder is already filled, unless `--force`.
  """

  use Mix.Task

  alias QemuAdmin.Qemu.{Esp, Installer}

  @target "qemu"
  @esp_target "qemu-esp"
  @cache ".cache"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [targets: :string, force: :boolean, esp: :boolean])

    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    targets =
      case opts[:targets] do
        nil -> Installer.default_targets()
        list -> String.split(list, ",", trim: true)
      end

    cond do
      not match?({:win32, _}, :os.type()) ->
        Mix.shell().info([
          :yellow,
          "QEMU portátil só existe para Windows. Instale o QEMU pelo gerenciador de pacotes; ",
          "o app o acha no PATH.",
          :reset
        ])

      File.regular?(Path.join(@target, "qemu-img.exe")) and !opts[:force] ->
        Mix.shell().info("qemu/ já tem QEMU (use --force para baixar de novo)")

      true ->
        if is_nil(Installer.seven_zip()) do
          Mix.shell().info([
            :yellow,
            "7-Zip não encontrado: o instalador do QEMU vai rodar em modo silencioso (pode pedir UAC).",
            :reset
          ])
        end

        Mix.shell().info([:cyan, "==> QEMU portátil (#{Enum.join(targets, ", ")})", :reset])

        case Installer.install(Path.expand(@target),
               targets: targets,
               cache_dir: Path.expand(@cache),
               progress: &progress/1
             ) do
          {:ok, dir} ->
            IO.write("\n")
            Mix.shell().info([:green, "* QEMU em ", :reset, dir, " (", size(dir), ")"])

          {:error, reason} ->
            IO.write("\n")
            Mix.raise("qemu.fetch: #{reason}")
        end
    end

    if Keyword.get(opts, :esp, true), do: fetch_esp(opts)
  end

  defp fetch_esp(opts) do
    if Esp.exe_in(Path.expand(@esp_target)) && !opts[:force] do
      Mix.shell().info("qemu-esp/ já tem o QEMU da Espressif (use --force para baixar de novo)")
    else
      Mix.shell().info([:cyan, "==> QEMU da Espressif (ESP32)", :reset])

      case Esp.install(Path.expand(@esp_target),
             cache_dir: Path.expand(@cache),
             progress: &progress/1
           ) do
        {:ok, dir} ->
          IO.write("\n")
          Mix.shell().info([:green, "* QEMU ESP32 em ", :reset, dir, " (", size(dir), ")"])

        {:error, reason} ->
          IO.write("\n")
          Mix.raise("qemu.fetch (esp): #{reason}")
      end
    end
  end

  defp progress({:resolve, url}), do: Mix.shell().info("  #{url}")

  defp progress({:download, {received, total}}) do
    # one line, rewritten — the download is ~200 MB
    if rem(div(received, 65_536), 32) == 0 do
      pct = if total, do: " #{div(received * 100, total)}%", else: ""
      IO.write("\r  baixando #{mb(received)}#{if total, do: " / #{mb(total)}"}#{pct}   ")
    end
  end

  defp progress({:verify, _}), do: IO.write("\n  verificando o checksum…")
  defp progress({:extract, _}), do: Mix.shell().info("\n  descompactando…")
  defp progress(_), do: :ok

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp size(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reduce(0, fn p, acc ->
      case File.stat(p) do
        {:ok, %{type: :regular, size: s}} -> acc + s
        _ -> acc
      end
    end)
    |> mb()
  end
end
