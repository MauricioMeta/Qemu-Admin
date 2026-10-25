defmodule QemuAdmin.Qemu.Installer do
  @moduledoc """
  Fetches a portable QEMU for Windows: the installer built by Stefan Weil
  (`qemu-w64-setup-YYYYMMDD.exe`, the build linked from qemu.org), checked
  against its published SHA-512 and unpacked into a folder — no admin
  rights, nothing in the registry.

  Used by `mix qemu.fetch` (into `qemu/`, which the release carries) and by
  the QEMU page of the app (into the data directory).

  The installer is NSIS, which 7-Zip unpacks directly; only the emulators of
  `targets` (and their UEFI images) are kept — the full set is ~1.2 GB of
  some thirty architectures. Without 7-Zip the installer itself runs silently
  (`/S /D=…`), which Windows may answer with a UAC prompt, and the folder is
  pruned afterwards.

  Progress goes to the `progress` callback as `{phase, detail}`:
  `{:resolve, url}`, `{:download, {received, total}}`, `{:verify, nil}`,
  `{:extract, nil}`, `{:done, dir}`.
  """

  @default_index "https://qemu.weilnetz.de/w64/"

  @doc "The emulators kept by default."
  def default_targets do
    Application.get_env(:qemu_admin, :qemu_fetch, [])[:targets] || ~w(x86_64 i386 aarch64 arm avr)
  end

  defp index_url do
    Application.get_env(:qemu_admin, :qemu_fetch, [])[:index_url] || @default_index
  end

  @doc """
  The newest build on the index: `{:ok, %{name:, version:, url:, sha_url:}}`.
  """
  def latest do
    with {:ok, %{status: 200, body: body}} <- Req.get(index_url(), retry: :transient) do
      ~r/qemu-w64-setup-(\d{8})\.exe/
      |> Regex.scan(body)
      |> Enum.map(fn [_, date] -> date end)
      |> Enum.uniq()
      |> Enum.max(fn -> nil end)
      |> case do
        nil -> {:error, "nenhum instalador encontrado em #{index_url()}"}
        date -> {:ok, build(date)}
      end
    else
      {:ok, %{status: status}} -> {:error, "#{index_url()} respondeu #{status}"}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  defp build(date) do
    name = "qemu-w64-setup-#{date}.exe"

    %{
      name: name,
      version: date,
      url: index_url() <> name,
      sha_url: index_url() <> "qemu-w64-setup-#{date}.sha512"
    }
  end

  @doc """
  Downloads (or reuses from `cache_dir`), verifies and unpacks the newest
  build into `target`. Options: `:targets`, `:cache_dir`, `:progress`.
  """
  def install(target, opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    targets = Keyword.get(opts, :targets, default_targets())
    cache = Keyword.get(opts, :cache_dir, Path.join(System.tmp_dir!(), "qemu_admin_cache"))

    with :ok <- windows_only(),
         {:ok, build} <- latest(),
         _ = progress.({:resolve, build.url}),
         {:ok, installer} <- fetch(build, cache, progress),
         _ = progress.({:extract, nil}),
         :ok <- unpack(installer, target, targets) do
      progress.({:done, target})
      {:ok, target}
    end
  end

  defp windows_only do
    if match?({:win32, _}, :os.type()),
      do: :ok,
      else: {:error, "o QEMU portátil é só para Windows — instale pelo gerenciador de pacotes"}
  end

  @doc "The installer in `cache`, downloaded if missing, always checked."
  def fetch(build, cache, progress \\ fn _ -> :ok end) do
    File.mkdir_p!(cache)
    path = Path.join(cache, build.name)

    with {:ok, expected} <- expected_sha(build) do
      if File.regular?(path) and sha512(path) == expected do
        {:ok, path}
      else
        with :ok <- download(build.url, path, progress) do
          progress.({:verify, nil})

          if sha512(path) == expected do
            {:ok, path}
          else
            File.rm(path)
            {:error, "SHA-512 de #{build.name} não confere — download corrompido"}
          end
        end
      end
    end
  end

  # "<128 hex>  qemu-w64-setup-….exe"
  defp expected_sha(build) do
    case Req.get(build.sha_url, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        case Regex.run(~r/\b([0-9a-fA-F]{128})\b/, to_string(body)) do
          [_, hex] -> {:ok, String.downcase(hex)}
          _ -> {:error, "#{build.sha_url} sem um SHA-512"}
        end

      {:ok, %{status: status}} ->
        {:error, "#{build.sha_url} respondeu #{status}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  @doc false
  def download(url, path, progress) do
    part = path <> ".part"

    result =
      File.open(part, [:write, :binary], fn io ->
        Req.get(url,
          raw: true,
          retry: :transient,
          receive_timeout: 60_000,
          into: fn {:data, data}, {req, resp} ->
            IO.binwrite(io, data)
            received = Process.get(:qa_received, 0) + byte_size(data)
            Process.put(:qa_received, received)
            total = resp |> Req.Response.get_header("content-length") |> List.first()
            progress.({:download, {received, total && String.to_integer(total)}})
            {:cont, {req, resp}}
          end
        )
      end)

    Process.delete(:qa_received)

    case result do
      {:ok, {:ok, %{status: 200}}} ->
        File.rename!(part, path)
        :ok

      {:ok, {:ok, %{status: status}}} ->
        File.rm(part)
        {:error, "#{url} respondeu #{status}"}

      {:ok, {:error, e}} ->
        File.rm(part)
        {:error, Exception.message(e)}

      {:error, reason} ->
        {:error, "não foi possível escrever #{part}: #{:file.format_error(reason)}"}
    end
  end

  def sha512(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha512), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Unpacks `installer` into `target` (replacing it), keeping `targets`. Into
  a sibling `.tmp` first, so a failure never leaves a half QEMU in place.
  """
  def unpack(installer, target, targets) do
    tmp = target <> ".tmp"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    result =
      case seven_zip() do
        nil -> run_installer(installer, tmp)
        exe -> extract_7z(exe, installer, tmp, targets)
      end

    with :ok <- result do
      prune(tmp, targets)
      File.rm_rf!(target)
      File.rename!(tmp, target)
      :ok
    else
      error ->
        File.rm_rf!(tmp)
        error
    end
  end

  @doc "7-Zip, if installed."
  def seven_zip do
    System.find_executable("7z") || System.find_executable("7za") ||
      Enum.find(
        ["C:/Program Files/7-Zip/7z.exe", "C:/Program Files (x86)/7-Zip/7z.exe"],
        &File.regular?/1
      )
  end

  defp extract_7z(exe, installer, dir, targets) do
    # Listing first, so the unwanted emulators are never written: excluding
    # them is cheaper than unpacking 1.2 GB and deleting most of it.
    with {out, 0} <- System.cmd(exe, ["l", "-ba", "-slt", installer], stderr_to_stdout: true) do
      excluded =
        ~r/^Path = (.+)$/m
        |> Regex.scan(out)
        |> Enum.map(fn [_, p] -> String.trim(p) end)
        |> Enum.reject(&keep?(&1, targets))

      list = Path.join(dir, "..exclude.txt")
      File.write!(list, Enum.join(excluded, "\r\n"))

      case System.cmd(exe, ["x", installer, "-o" <> dir, "-y", "-bd", "-x@" <> list],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          File.rm(list)
          :ok

        {out, status} ->
          {:error, "7-Zip falhou (#{status}): #{String.slice(out, -400, 400)}"}
      end
    else
      {out, status} -> {:error, "7-Zip falhou (#{status}): #{String.slice(out, -400, 400)}"}
    end
  end

  defp run_installer(installer, dir) do
    # NSIS: /D must be the last argument and is taken verbatim (no quotes).
    win_dir = String.replace(dir, "/", "\\")

    case System.cmd(installer, ["/S", "/D=" <> win_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, "o instalador falhou (#{status}) #{out}"}
    end
  end

  @doc """
  Whether the archive entry `path` (backslashes, relative) is kept for
  `targets`.
  """
  def keep?(path, targets) do
    path = String.replace(path, "\\", "/")
    base = Path.basename(path)

    cond do
      String.starts_with?(path, "$") ->
        false

      String.starts_with?(path, "share/doc") ->
        false

      String.starts_with?(path, "share/man") ->
        false

      base in ["uninstall.exe", "qemu-nsis.bmp"] ->
        false

      String.starts_with?(base, "qemu-system-") ->
        emulator_kept?(base, targets)

      String.starts_with?(base, "edk2-") and not String.ends_with?(base, ".txt") ->
        firmware_kept?(base, targets)

      true ->
        true
    end
  end

  # qemu-system-x86_64.exe yes, qemu-system-x86_64w.exe (the console-less
  # twin) no: the app reads the emulator's output through a pipe.
  defp emulator_kept?(base, targets) do
    arch = base |> String.replace_prefix("qemu-system-", "") |> String.replace_suffix(".exe", "")
    arch in targets
  end

  @firmware %{
    "x86_64" => ~w(edk2-x86_64- edk2-i386-vars),
    "i386" => ~w(edk2-i386-),
    "aarch64" => ~w(edk2-aarch64- edk2-arm-vars)
  }

  defp firmware_kept?(base, targets) do
    targets
    |> Enum.flat_map(&Map.get(@firmware, &1, []))
    |> Enum.any?(&String.starts_with?(base, &1))
  end

  # After the silent installer (which writes everything), or as a second
  # pass after 7-Zip: drops what `keep?/2` would not have kept.
  defp prune(dir, targets) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
        rel = Path.relative_to(path, dir),
        not keep?(rel, targets) do
      File.rm_rf(path)
    end

    :ok
  end
end
