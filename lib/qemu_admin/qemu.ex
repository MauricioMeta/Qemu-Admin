defmodule QemuAdmin.Qemu do
  @moduledoc """
  Finds the QEMU binaries. The first folder holding a `qemu-img` wins:

    1. the setting `qemu_dir` (Configurações › QEMU);
    2. the **bundled** one: `qemu/` in the release (`$RELEASE_ROOT/qemu`,
       copied there by the release step in `mix.exs`) or, in dev, at the
       project root — both filled by `mix qemu.fetch`;
    3. the one **downloaded** from the app (`QemuAdmin.Qemu.Installer`, in
       the data directory);
    4. the `PATH`;
    5. the default install folder (`C:\\Program Files\\qemu`, `/usr/bin`…).

  `info/0` describes what was found (folder, source, version, emulators,
  accelerators) and is cached until `refresh/0` — after an install or a
  change of the setting.
  """

  alias QemuAdmin.{Paths, Settings}

  @key {__MODULE__, :info}

  @doc """
  The emulator architectures the app knows how to configure. `xtensa` is
  the ESP32, from Espressif's own QEMU (`QemuAdmin.Qemu.Esp`); `avr` the
  Arduinos and `arm` (with `aarch64`) the Raspberry Pis.
  """
  def arches, do: ~w(x86_64 i386 aarch64 arm avr xtensa)

  @doc """
  What QEMU is in use: `%{dir:, source:, version:, emulators:, accels:}`,
  or `%{dir: nil, source: nil, …}` when there is none.
  """
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

  @doc "Forgets the cached `info/0` (after an install or a settings change)."
  def refresh do
    :persistent_term.erase(@key)
    Enum.each(arches(), &:persistent_term.erase({__MODULE__, :machines, &1}))
    QemuAdmin.Qemu.Esp.refresh()
    info()
  end

  def available?, do: info().dir != nil

  @doc "The folder in use, or nil."
  def dir, do: info().dir

  @doc "Full path of a QEMU executable (`\"qemu-img\"`, `\"qemu-system-x86_64\"`)."
  def exe(name) do
    case dir() do
      nil -> {:error, :no_qemu}
      dir -> exe_in(dir, name)
    end
  end

  def exe!(name) do
    case exe(name) do
      {:ok, path} -> path
      {:error, reason} -> raise "QEMU: #{name} não encontrado (#{reason})"
    end
  end

  @doc "The emulator's file name as the command line shows it, found or not."
  def exe_name(arch) do
    case system_exe(arch) do
      {:ok, exe} -> exe
      _ -> "qemu-system-#{arch}"
    end
  end

  def system_exe("xtensa"), do: QemuAdmin.Qemu.Esp.exe()
  def system_exe(arch), do: exe("qemu-system-#{arch}")

  @doc """
  The firmware file `name` (`edk2-x86_64-code.fd`…): in `share/` beside the
  binaries (Windows builds) or in the distributions' data folders.
  """
  def firmware(name) do
    [
      dir() && Path.join(dir(), "share"),
      "/usr/share/qemu",
      "/usr/local/share/qemu",
      "/opt/homebrew/share/qemu",
      "/usr/share/edk2/ovmf"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&File.regular?/1)
  end

  @doc "The candidate folders, in order, each with its source."
  def candidates do
    [
      {:settings,
       with(
         dir when is_binary(dir) and dir != "" <- Settings.get(:qemu_dir),
         do: Path.expand(dir)
       )},
      {:bundled, bundled_dir()},
      {:downloaded, Paths.downloaded_qemu_dir()},
      {:path, path_dir()}
    ] ++ Enum.map(system_dirs(), &{:system, &1})
  end

  @doc "Where `mix qemu.fetch` puts QEMU and where the release carries it."
  def bundled_dir do
    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) and root != "" -> root |> Path.expand() |> Path.join("qemu")
      _ -> Path.expand("qemu", File.cwd!())
    end
  end

  def source_label(:settings), do: "Configurações"
  def source_label(:bundled), do: "Embutido no app"
  def source_label(:downloaded), do: "Baixado pelo app"
  def source_label(:path), do: "PATH do sistema"
  def source_label(:system), do: "Instalação do sistema"
  def source_label(_), do: "—"

  @doc """
  Every machine `qemu-system-<arch>` emulates (`-M help`): `%{name:,
  description:, default?:, alias_of:}`, sorted by name; `[]` when the
  emulator is missing. Cached until `refresh/0`. Only some are ones the app
  knows how to configure (`QemuAdmin.Vm.machines/1`).
  """
  def machines(arch) do
    key = {__MODULE__, :machines, arch}

    case :persistent_term.get(key, nil) do
      nil ->
        list = read_machines(arch)
        :persistent_term.put(key, list)
        list

      list ->
        list
    end
  end

  defp read_machines(arch) do
    with {:ok, exe} <- system_exe(arch),
         {out, 0} <- run(exe, ["-machine", "help"]) do
      out
      |> String.split(~r/\R/, trim: true)
      |> Enum.flat_map(&parse_machine/1)
      |> Enum.sort_by(& &1.name)
    else
      _ -> []
    end
  end

  # "q35   Standard PC (Q35 + ICH9, 2009) (alias of pc-q35-11.1)"
  defp parse_machine(line) do
    case Regex.run(~r/^(\S+)\s+(.+)$/, String.trim_trailing(line)) do
      [_, name, rest] when name != "Supported" ->
        alias_of =
          case Regex.run(~r/\(alias of ([^)]+)\)\s*$/, rest) do
            [_, target] -> target
            _ -> nil
          end

        description =
          rest
          |> String.replace(~r/\s*\((alias of [^)]+|default)\)\s*$/, "")
          |> String.trim()

        [%{name: name, description: description, default?: String.ends_with?(rest, "(default)"), alias_of: alias_of}]

      _ ->
        []
    end
  end

  defp probe do
    esp = if QemuAdmin.Qemu.Esp.available?(), do: ["xtensa"], else: []

    case Enum.find(candidates(), fn {_src, dir} -> valid_dir?(dir) end) do
      nil ->
        %{dir: nil, source: nil, version: nil, emulators: esp, accels: []}

      {source, dir} ->
        emulators = Enum.filter(arches(), &match?({:ok, _}, exe_in(dir, "qemu-system-#{&1}")))

        %{
          dir: dir,
          source: source,
          version: version(dir, emulators),
          emulators: emulators ++ esp,
          accels: accels(dir, emulators)
        }
    end
  end

  defp valid_dir?(dir) when is_binary(dir) and dir != "",
    do: match?({:ok, _}, exe_in(dir, "qemu-img"))

  defp valid_dir?(_), do: false

  defp exe_in(dir, name) do
    path = Path.join(dir, name <> exe_ext())
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  defp exe_ext, do: if(windows?(), do: ".exe", else: "")

  def windows?, do: match?({:win32, _}, :os.type())

  defp path_dir do
    case System.find_executable("qemu-img") do
      nil -> nil
      exe -> Path.dirname(exe)
    end
  end

  defp system_dirs do
    case :os.type() do
      {:win32, _} -> ["C:/Program Files/qemu"]
      {:unix, :darwin} -> ["/opt/homebrew/bin", "/usr/local/bin"]
      _ -> ["/usr/bin", "/usr/local/bin"]
    end
  end

  # "QEMU emulator version 11.1.0 (v11.1.0-…)" → "11.1.0"
  defp version(dir, emulators) do
    exe =
      case emulators do
        [arch | _] -> exe_in(dir, "qemu-system-#{arch}")
        [] -> exe_in(dir, "qemu-img")
      end

    with {:ok, exe} <- exe,
         {out, 0} <- run(exe, ["--version"]),
         [_, v] <- Regex.run(~r/version\s+([\w.\-]+)/, out) do
      v
    else
      _ -> nil
    end
  end

  # "Accelerators supported in QEMU binary:\ntcg\nwhpx\n" → ["tcg", "whpx"]
  defp accels(dir, emulators) do
    arch = if "x86_64" in emulators, do: "x86_64", else: List.first(emulators)

    with arch when is_binary(arch) <- arch,
         {:ok, exe} <- exe_in(dir, "qemu-system-#{arch}"),
         {out, 0} <- run(exe, ["-accel", "help"]) do
      out
      |> String.split(~r/\R/, trim: true)
      |> Enum.drop(1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  defp run(exe, args) do
    System.cmd(exe, args, stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end
end
