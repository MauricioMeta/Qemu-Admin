defmodule QemuAdmin.Terminal do
  @moduledoc """
  What the Terminal (the page's prompt, `QemuAdminWeb.Components.Vm.Terminal`)
  does besides talking to a running QEMU through QMP (`QemuAdmin.VmServer.console/2`):
  the QEMU **tools** — `qemu-img`, `qemu-io` and the introspection of
  `qemu-system-*` (`-machine help`, `-cpu help`, `-version`…) — which need no VM
  running. `route/1` tells what an input is; `run/2` runs a tool in the VM's
  folder (so a disk is just `disk0.qcow2`), without a shell, with a time limit
  and an output limit.

  `log/3` adds an entry to the VM's command history (`VmServer.commands/1`):
  through the running `VmServer`, which numbers and keeps it, or, with the VM
  off, straight into its `commands.log` — the file the next run starts over.
  """

  alias QemuAdmin.{Qemu, Vm, VmServer}

  @timeout 30_000
  @max_output 65_536

  # the options of qemu-system-* that list what QEMU has and exit
  @help_options ~w(-machine -M -cpu -accel -device -driver -netdev -object -chardev -audiodev
                   -display -nic -drive -blockdev -d -smbios -global)
  @info_flags ~w(-h -help --help -version --version -V)

  @doc """
  What `input` is: `{:tool, name}` (a QEMU tool, whose name the first word is),
  `{:error, message}` (a tool called in a way that is not allowed) or `:monitor`
  (anything else: a monitor or QMP command, which needs the VM running).
  """
  def route(input) do
    case Vm.split_args(String.trim(input)) do
      {:ok, [first | args]} -> route_tool(tool_name(first), args)
      {:ok, []} -> :monitor
      {:error, _} -> :monitor
    end
  end

  defp route_tool("qemu-img", _args), do: {:tool, "qemu-img"}

  defp route_tool("qemu-io", args) do
    if Enum.any?(args, &(&1 in ~w(-c --cmd -h --help -V --version))),
      do: {:tool, "qemu-io"},
      else: {:error, "o qemu-io é interativo: dê o comando com -c, por exemplo qemu-io -c \"read 0 512\" disco.img"}
  end

  defp route_tool("qemu-system-" <> arch = name, args) do
    cond do
      arch not in Qemu.arches() ->
        :monitor

      introspection?(args) ->
        {:tool, name}

      true ->
        {:error,
         "o #{name} só roda aqui para listar o que o QEMU tem (-machine help, -cpu help, " <>
           "-device help, -version…); para iniciar a VM use o botão Ligar"}
    end
  end

  defp route_tool(_other, _args), do: :monitor

  defp tool_name(word) do
    word |> String.downcase() |> Path.basename() |> String.replace_suffix(".exe", "")
  end

  defp introspection?(args) do
    Enum.any?(args, &(&1 in @info_flags)) or
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [opt, value] ->
        opt in @help_options and (value == "help" or String.ends_with?(value, ",help"))
      end)
  end

  @doc """
  Runs the tool the first word of `input` names, in the VM's folder.
  `{:ok, output, exit_status}` (stdout and stderr together) or `{:error, message}`.
  """
  def run(%Vm{} = vm, input) do
    with {:tool, name} <- route(input),
         {:ok, [_ | args]} <- Vm.split_args(String.trim(input)),
         {:ok, exe} <- find(name) do
      File.mkdir_p!(Vm.dir(vm))
      execute(exe, args, Vm.dir(vm))
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, :no_qemu} -> {:error, "QEMU não encontrado: veja a página QEMU"}
      _ -> {:error, "não é uma ferramenta do QEMU"}
    end
  end

  defp find("qemu-system-" <> arch), do: Qemu.system_exe(arch)
  defp find(name), do: Qemu.exe(name)

  defp execute(exe, args, dir) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, args},
        {:cd, dir}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    collect(port, os_pid, [], 0, System.monotonic_time(:millisecond) + @timeout)
  rescue
    e -> {:error, "não foi possível executar: #{Exception.message(e)}"}
  end

  defp collect(port, os_pid, chunks, size, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {chunks, size} = if size < @max_output, do: {[data | chunks], size + byte_size(data)}, else: {chunks, size}
        collect(port, os_pid, chunks, size, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, output(chunks, size), status}
    after
      left ->
        kill(os_pid)
        Port.close(port)
        {:error, "tempo esgotado (#{div(@timeout, 1000)} s): o comando foi encerrado"}
    end
  end

  defp output(chunks, size) do
    text = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> utf8()
    text = String.trim_trailing(text)
    if size >= @max_output, do: text <> "\n… (saída cortada)", else: text
  end

  # QEMU on Windows may print in the console's code page, not UTF-8
  defp utf8(text) do
    if String.valid?(text),
      do: text,
      else: :unicode.characters_to_binary(text, :latin1, :utf8)
  end

  defp kill(os_pid) do
    case :os.type() do
      {:win32, _} -> System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)
      _ -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end
  catch
    _, _ -> :ok
  end

  # ------------------------------------------------------------- history

  @doc """
  Adds an entry (`dir`: `"tool"`, `"typed"`, `"received"` or `"error"`) to the
  VM's history, and broadcasts it as `{:vm_cmd, id, entry}`.
  """
  def log(id, dir, text) do
    case VmServer.log_command(id, dir, text) do
      :ok -> :ok
      {:error, :not_running} -> append(id, dir, text)
    end
  end

  # the VM is off: the file is the history
  defp append(id, dir, text) do
    last = VmServer.commands(id) |> List.last()
    seq = if last, do: last.seq + 1, else: 1
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    entry = %{seq: seq, at: at, dir: dir, text: text}
    path = VmServer.commands_path(id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(entry), "\n"], [:append])
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), {:vm_cmd, id, entry})
    :ok
  end
end
