defmodule QemuAdmin.Renode do
  @moduledoc """
  The Renode emulator (https://renode.io) as the app's second engine, next to QEMU.

  A VM whose `arch` is `"renode"` (`QemuAdmin.Vm.kind/1` → `:renode`) is run by
  `QemuAdmin.RenodeServer`: its `machine` is one of Renode's board descriptions
  (`platforms/boards/<machine>.repl`), its program (`Vm` `program`, see
  `QemuAdmin.Firmwares`) is loaded into the board and its UART (`Vm` `uart`, the
  board's first one by default) is served on a loopback port the page reads, like a
  QEMU board's.

  Renode is looked for where `mix qemu.fetch` leaves the QEMU: `renode/` beside the
  app (`RELEASE_ROOT` in a release), in a `renode_*-portable` folder or directly;
  else `renode` in the PATH.
  """

  @key {__MODULE__, :info}

  @doc "`%{dir:, exe:, version:}`; `dir` and `exe` are nil when Renode was not found."
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

  @doc "Forgets what was found (after installing)."
  def refresh, do: :persistent_term.erase(@key)

  def available?, do: info().exe != nil

  @doc "`{:ok, path}` of the Renode executable, or `{:error, :no_renode}`."
  def exe do
    case info().exe do
      nil -> {:error, :no_renode}
      path -> {:ok, path}
    end
  end

  @doc "Where the portable Renode is looked for."
  def bundled_dir do
    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) and root != "" -> root |> Path.expand() |> Path.join("renode")
      _ -> Path.expand("renode", File.cwd!())
    end
  end

  defp probe do
    case Enum.find_value(candidates(), &find_exe/1) do
      nil -> %{dir: nil, exe: nil, version: nil}
      {dir, exe} -> %{dir: dir, exe: exe, version: version(dir)}
    end
  end

  defp candidates do
    base = bundled_dir()
    portable = Path.wildcard(Path.join(base, "renode_*-portable"))
    portable ++ [base] ++ path_dirs()
  end

  defp path_dirs do
    case System.find_executable("renode") do
      nil -> []
      exe -> [Path.dirname(exe)]
    end
  end

  defp find_exe(dir) do
    name = if match?({:win32, _}, :os.type()), do: "renode.exe", else: "renode"
    exe = Path.join(dir, name)
    if File.regular?(exe), do: {dir, exe}
  end

  # "renode_1.17.0-portable" → "1.17.0"; the Renode.deps.json has no version, so the folder says it
  defp version(dir) do
    case Regex.run(~r/renode[_-]v?(\d+(?:\.\d+)+)/i, Path.basename(dir)) do
      [_, v] -> v
      _ -> nil
    end
  end

  @doc "The folder with the board descriptions (`platforms/boards`), or nil."
  def boards_dir do
    with %{dir: dir} when is_binary(dir) <- info(),
         boards = Path.join([dir, "platforms", "boards"]),
         true <- File.dir?(boards) do
      boards
    else
      _ -> nil
    end
  end

  @doc "The boards Renode describes (`platforms/boards/*.repl`), by name, sorted."
  def platforms do
    case boards_dir() do
      nil ->
        []

      dir ->
        dir
        |> Path.join("*.repl")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".repl"))
        |> Enum.sort()
    end
  end

  @doc "The `.repl` file of a board, or nil."
  def platform_file(machine) do
    with dir when is_binary(dir) <- boards_dir(),
         file = Path.join(dir, "#{machine}.repl"),
         true <- File.regular?(file) do
      file
    else
      _ -> nil
    end
  end

  @doc """
  The UARTs a board has (`usart2: UART.STM32_UART @ sysbus …`), in file order. A board
  usually takes its chip from another file (`using "platforms/cpus/stm32f4.repl"`),
  where the UARTs are: the `using`s are followed.
  """
  def uarts(machine) do
    case platform_file(machine) do
      nil -> []
      file -> file |> uarts_in(0) |> Enum.uniq()
    end
  end

  defp uarts_in(_file, depth) when depth > 3, do: []

  defp uarts_in(file, depth) do
    case File.read(file) do
      {:ok, text} ->
        own = for [_, name] <- Regex.scan(~r/^(\w+):\s+(?:UART|Serial)\.\w+/m, text), do: name

        included =
          for [_, ref] <- Regex.scan(~r/^using\s+"([^"]+)"/m, text),
              inc <- [included_file(file, ref)],
              inc != nil,
              name <- uarts_in(inc, depth + 1),
              do: name

        own ++ included

      _ ->
        []
    end
  end

  # `using "platforms/cpus/x.repl"` is relative to Renode's folder; a bare name, to the file's own
  defp included_file(file, ref) do
    root = info().dir

    [root && Path.join(root, ref), Path.join(Path.dirname(file), ref)]
    |> Enum.find(&(&1 && File.regular?(&1)))
  end

  @doc "The UART the VM prints on: the one it names, else the board's first."
  def uart(vm) do
    uarts = uarts(vm.machine)

    cond do
      vm.uart in uarts -> vm.uart
      uarts != [] -> hd(uarts)
      true -> nil
    end
  end

  @doc "The Renode script (`.resc`) of a run: the board, its UART as a socket, the program."
  def script(vm, ports, program) do
    platform = platform_file(vm.machine)

    [
      ~s|mach create "#{String.replace(vm.name, "\"", "")}"|,
      "machine LoadPlatformDescription #{path(platform)}",
      ~s|emulation CreateServerSocketTerminal #{ports.serial} "uart_term" false|,
      if(uart = uart(vm), do: "connector Connect sysbus.#{uart} uart_term"),
      load(program)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp load(nil), do: nil

  defp load(file) do
    case file |> Path.extname() |> String.downcase() do
      ".hex" -> "sysbus LoadHEX #{path(file)}"
      _ -> "sysbus LoadELF #{path(file)}"
    end
  end

  # A path in quotes stays in one piece when it has spaces (`@"…"` does not tokenize)
  defp path(file), do: ~s|"#{String.replace(file, "\\", "/")}"|

  @doc "The arguments of the Renode process: no windows, the monitor on a port, the VM's script."
  def args(vm, ports) do
    # the page only previews the line with its stand-in ports: they have no `monitor`
    monitor = Map.get(ports, :monitor, Map.get(ports, :qmp, 0))
    ["--disable-xwt", "--plain", "--port", to_string(monitor), script_path(vm)]
  end

  def script_path(vm), do: Path.join(QemuAdmin.Vm.dir(vm), "run.resc")
end
