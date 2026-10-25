defmodule QemuAdmin.Esp32.AtomVM do
  @moduledoc """
  AtomVM — the BEAM for microcontrollers — on an emulated ESP32.

  Its releases on GitHub carry one image per chip
  (`AtomVM-esp32-v0.6.6.img`, `AtomVM-esp32-elixir-v0.6.6.img` with the
  Elixir libraries in `boot.avm`): bootloader, partition table and the VM,
  written at the chip's bootloader offset, each with a `.sha256` beside it.
  `fetch/3` downloads and checks one into the data directory's
  `firmware/`; `install/3` puts it on a VM's flash. The app itself, an
  `.avm` built with `mix atomvm.packbeam` or `rebar3 atomvm packbeam`, then
  goes in the `main.avm` partition (`QemuAdmin.Esp32.Flash`).
  """

  alias QemuAdmin.Esp32.Flash
  alias QemuAdmin.Paths

  @releases "https://api.github.com/repos/atomvm/AtomVM/releases?per_page=30"

  @doc "Where downloaded images are kept."
  def cache_dir, do: Path.join(Paths.data_dir(), "firmware")

  @doc "The image's file name: `AtomVM-esp32-elixir-v0.6.6.img`."
  def image_name(chip, tag, flavor) do
    "AtomVM-#{chip}#{if flavor == "elixir", do: "-elixir"}-#{tag}.img"
  end

  @doc """
  The releases with an image for `chip`, newest first:
  `{:ok, [%{tag:, prerelease:}]}`.
  """
  def releases(chip) do
    case Req.get(@releases,
           retry: :transient,
           headers: [{"accept", "application/vnd.github+json"}]
         ) do
      {:ok, %{status: 200, body: list}} when is_list(list) ->
        {:ok,
         for r <- list,
             not r["draft"],
             Enum.any?(r["assets"], &(&1["name"] == image_name(chip, r["tag_name"], "erlang"))) do
           %{tag: r["tag_name"], prerelease: r["prerelease"]}
         end}

      {:ok, %{status: status}} ->
        {:error, "GitHub respondeu #{status}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  @doc "The image for `chip`/`tag`/`flavor` (`\"erlang\"` or `\"elixir\"`), downloaded if missing, always checked."
  def fetch(chip, tag, flavor) do
    name = image_name(chip, tag, flavor)
    url = "https://github.com/atomvm/AtomVM/releases/download/#{tag}/#{name}"
    path = Path.join(cache_dir(), name)
    File.mkdir_p!(cache_dir())

    with {:ok, expected} <- expected_sha(url <> ".sha256") do
      cond do
        File.regular?(path) and QemuAdmin.Qemu.Esp.sha256(path) == expected ->
          {:ok, path}

        true ->
          case Req.get(url, retry: :transient, into: File.stream!(path <> ".part")) do
            {:ok, %{status: 200}} ->
              if QemuAdmin.Qemu.Esp.sha256(path <> ".part") == expected do
                File.rename!(path <> ".part", path)
                {:ok, path}
              else
                File.rm(path <> ".part")
                {:error, "SHA-256 de #{name} não confere"}
              end

            {:ok, %{status: 404}} ->
              File.rm(path <> ".part")
              {:error, "#{name} não existe em #{tag}"}

            {:ok, %{status: status}} ->
              File.rm(path <> ".part")
              {:error, "#{name}: GitHub respondeu #{status}"}

            {:error, e} ->
              File.rm(path <> ".part")
              {:error, Exception.message(e)}
          end
      end
    end
  end

  defp expected_sha(url) do
    case Req.get(url, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        case Regex.run(~r/\b([0-9a-fA-F]{64})\b/, to_string(body)) do
          [_, hex] -> {:ok, String.downcase(hex)}
          _ -> {:error, "#{url} sem um SHA-256"}
        end

      {:ok, %{status: 404}} ->
        {:error, "esta versão não tem imagem para o chip (#{Path.basename(url, ".sha256")})"}

      {:ok, %{status: status}} ->
        {:error, "#{url} respondeu #{status}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Erases the flash at `flash` and writes the AtomVM `image` at the
  bootloader offset of `machine` — a freshly flashed chip.
  """
  def install(flash, machine, image) do
    with {:ok, data} <- File.read(image),
         :ok <- Flash.erase(flash) do
      Flash.write(flash, Flash.bootloader_offset(machine), data)
    end
  end

  @doc """
  Writes the app `avm` into the partition `name` (`main.avm`), erasing it
  first. Checks it is an AtomVM pack (`#!/usr/bin/env AtomVM` header) and
  that it fits.
  """
  def write_app(flash, avm, name \\ "main.avm") do
    with {:ok, data} <- File.read(avm),
         :ok <- avm?(data),
         %{} = part <-
           Flash.partition(flash, name) ||
             {:error, "a flash não tem a partição #{name} — grave o AtomVM primeiro"},
         :ok <- fits(data, part) do
      Flash.write(flash, part.offset, data, erase: {part.offset, part.size})
    end
  end

  defp avm?(<<"#!/usr/bin/env AtomVM", _::binary>>), do: :ok
  defp avm?(_), do: {:error, "não é um arquivo .avm do AtomVM (gere com mix atomvm.packbeam)"}

  defp fits(data, part) do
    if byte_size(data) <= part.size,
      do: :ok,
      else:
        {:error,
         "#{byte_size(data)} bytes não cabem na partição #{part.name} (#{part.size} bytes)"}
  end
end
