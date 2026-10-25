defmodule QemuAdmin.Qemu.Esp do
  @moduledoc """
  Espressif's QEMU — the fork that emulates the ESP32 chips (upstream QEMU
  has none). Only `qemu-system-xtensa` is used: the `esp32` and `esp32s3`
  boards, booting a SPI flash image, with the UART on a socket.

  The first folder holding `bin/qemu-system-xtensa` wins:

    1. the **bundled** one: `qemu-esp/` beside `qemu/` (the release root or,
       in dev, the project root), filled by `mix qemu.fetch`;
    2. the one **downloaded** from the QEMU page (`qemu-esp/` in the data
       directory);
    3. ESP-IDF's own copy (`~/.espressif/tools/qemu-xtensa/*/qemu`);
    4. the `PATH`.

  Downloading it is `install/2`: the newest release of espressif/qemu on
  GitHub for this host, checked against its published SHA-256 and unpacked
  with `tar` (Windows 10+ ships one that reads `.tar.xz`).
  """

  alias QemuAdmin.Paths
  alias QemuAdmin.Qemu.Installer

  @key {__MODULE__, :info}
  @releases "https://api.github.com/repos/espressif/qemu/releases/latest"

  @doc "The boards of `qemu-system-xtensa` the app configures."
  def machines, do: ~w(esp32 esp32s3)

  @doc "`%{dir:, source:, exe:, version:}` (all nil when there is none). Cached until `refresh/0`."
  def info do
    case :persistent_term.get(@key, nil) do
      nil ->
        info = probe()
        :persistent_term.put(@key, info)
        info

      info ->
        info
    end
  end

  def refresh do
    :persistent_term.erase(@key)
    info()
  end

  def available?, do: info().exe != nil

  def exe do
    case info().exe do
      nil -> {:error, :no_qemu}
      exe -> {:ok, exe}
    end
  end

  @doc "The candidate folders, in order, each with its source."
  def candidates do
    [
      {:bundled, bundled_dir()},
      {:downloaded, downloaded_dir()}
    ] ++
      Enum.map(idf_dirs(), &{:idf, &1}) ++
      [{:path, path_dir()}]
  end

  @doc "Where `mix qemu.fetch` puts it and the release carries it: `qemu-esp/` beside `qemu/`."
  def bundled_dir, do: QemuAdmin.Qemu.bundled_dir() |> Path.dirname() |> Path.join("qemu-esp")

  def downloaded_dir, do: Path.join(Paths.data_dir(), "qemu-esp")

  def source_label(:bundled), do: "Embutido no app"
  def source_label(:downloaded), do: "Baixado pelo app"
  def source_label(:idf), do: "ESP-IDF"
  def source_label(:path), do: "PATH do sistema"
  def source_label(_), do: "—"

  defp idf_dirs do
    case System.user_home() do
      nil ->
        []

      home ->
        home
        |> Path.join(".espressif/tools/qemu-xtensa/*/qemu")
        |> Path.wildcard()
        |> Enum.sort(:desc)
    end
  end

  # The PATH holds `…/qemu/bin`; the folder is its parent.
  defp path_dir do
    case System.find_executable("qemu-system-xtensa") do
      nil -> nil
      exe -> exe |> Path.dirname() |> Path.dirname()
    end
  end

  def exe_in(dir) when is_binary(dir) do
    path = Path.join([dir, "bin", "qemu-system-xtensa" <> ext()])
    if File.regular?(path), do: path
  end

  def exe_in(_), do: nil

  defp ext, do: if(QemuAdmin.Qemu.windows?(), do: ".exe", else: "")

  defp probe do
    Enum.find_value(candidates(), %{dir: nil, source: nil, exe: nil, version: nil}, fn {source,
                                                                                        dir} ->
      if exe = exe_in(dir) do
        %{dir: dir, source: source, exe: exe, version: version(exe)}
      end
    end)
  end

  # "QEMU emulator version 9.2.2 (esp_develop_9.2.2_20260417)" → "9.2.2 (esp_develop_9.2.2_20260417)"
  defp version(exe) do
    with {out, 0} <- System.cmd(exe, ["--version"], stderr_to_stdout: true),
         [_, v] <- Regex.run(~r/version\s+([^\r\n]+)/, out) do
      String.trim(v)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ------------------------------------------------------------ download

  @doc "This host's name in the release's file names, or nil."
  def host_triple do
    arch = to_string(:erlang.system_info(:system_architecture))
    arm? = arch =~ ~r/aarch64|arm64/

    case :os.type() do
      {:win32, _} -> "x86_64-w64-mingw32"
      {:unix, :darwin} -> if arm?, do: "aarch64-apple-darwin", else: "x86_64-apple-darwin"
      {:unix, :linux} -> if arm?, do: "aarch64-linux-gnu", else: "x86_64-linux-gnu"
      _ -> nil
    end
  end

  @doc """
  The newest release for this host:
  `{:ok, %{name:, version:, url:, sha_url:}}`.
  """
  def latest do
    with triple when is_binary(triple) <-
           host_triple() || {:error, "sem build da Espressif para este sistema"},
         {:ok, %{status: 200, body: %{"tag_name" => tag, "assets" => assets}}} <-
           Req.get(@releases,
             retry: :transient,
             headers: [{"accept", "application/vnd.github+json"}]
           ),
         %{} = asset <-
           Enum.find(assets, &(&1["name"] =~ ~r/^qemu-xtensa-softmmu-.*-#{triple}\.tar\.xz$/)) ||
             {:error, "#{tag} não tem build para #{triple}"},
         %{} = sums <-
           Enum.find(assets, &String.ends_with?(&1["name"], "-checksum.sha256")) ||
             {:error, "#{tag} sem arquivo de checksums"} do
      {:ok,
       %{
         name: asset["name"],
         version: tag,
         url: asset["browser_download_url"],
         sha_url: sums["browser_download_url"]
       }}
    else
      {:ok, %{status: status}} -> {:error, "GitHub respondeu #{status}"}
      {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Downloads (or reuses from `:cache_dir`), verifies and unpacks the newest
  release into `target`. Same `:progress` events as `QemuAdmin.Qemu.Installer`.
  """
  def install(target, opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    cache = Keyword.get(opts, :cache_dir, Path.join(System.tmp_dir!(), "qemu_admin_cache"))

    with {:ok, build} <- latest(),
         _ = progress.({:resolve, build.url}),
         {:ok, archive} <- fetch(build, cache, progress),
         _ = progress.({:extract, nil}),
         :ok <- unpack(archive, target) do
      refresh()
      progress.({:done, target})
      {:ok, target}
    end
  end

  defp fetch(build, cache, progress) do
    File.mkdir_p!(cache)
    path = Path.join(cache, build.name)

    with {:ok, expected} <- expected_sha(build) do
      if File.regular?(path) and sha256(path) == expected do
        {:ok, path}
      else
        with :ok <- Installer.download(build.url, path, progress) do
          progress.({:verify, nil})

          if sha256(path) == expected do
            {:ok, path}
          else
            File.rm(path)
            {:error, "SHA-256 de #{build.name} não confere — download corrompido"}
          end
        end
      end
    end
  end

  # "<64 hex> *qemu-xtensa-softmmu-….tar.xz", one per file
  defp expected_sha(build) do
    case Req.get(build.sha_url, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        case Regex.run(
               ~r/^([0-9a-fA-F]{64})\s+\*?#{Regex.escape(build.name)}\s*$/m,
               to_string(body)
             ) do
          [_, hex] -> {:ok, String.downcase(hex)}
          _ -> {:error, "#{build.name} não está nos checksums da release"}
        end

      {:ok, %{status: status}} ->
        {:error, "#{build.sha_url} respondeu #{status}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  def sha256(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Unpacks the release's `qemu/` into `target` (replacing it), through a
  sibling `.tmp`. Keeps `bin/qemu-system-xtensa` and the ROMs in `share/`;
  the console-less twin (`…w.exe`) and the headers go.
  """
  def unpack(archive, target) do
    tmp = target <> ".tmp"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    with {:ok, tar} <- tar(),
         {_, 0} <- System.cmd(tar, ["-xJf", archive, "-C", tmp], stderr_to_stdout: true),
         root = Path.join(tmp, "qemu"),
         true <- exe_in(root) != nil || {:error, "o pacote não tem bin/qemu-system-xtensa"} do
      File.rm_rf!(Path.join(root, "include"))
      File.rm_rf!(Path.join(root, "lib"))
      File.rm(Path.join([root, "bin", "qemu-system-xtensaw.exe"]))
      File.rm_rf!(target)
      File.mkdir_p!(Path.dirname(target))
      File.rename!(root, target)
      File.rm_rf!(tmp)
      :ok
    else
      {out, status} when is_binary(out) ->
        File.rm_rf!(tmp)
        {:error, "tar falhou (#{status}): #{String.slice(out, -400, 400)}"}

      {:error, _} = error ->
        File.rm_rf!(tmp)
        error
    end
  end

  # Windows' own bsdtar first: Git's GNU tar wants /c/… paths and may lack xz.
  defp tar do
    windows_tar = "C:/Windows/System32/tar.exe"

    cond do
      QemuAdmin.Qemu.windows?() and File.regular?(windows_tar) -> {:ok, windows_tar}
      exe = System.find_executable("tar") -> {:ok, exe}
      true -> {:error, "tar não encontrado"}
    end
  end
end
