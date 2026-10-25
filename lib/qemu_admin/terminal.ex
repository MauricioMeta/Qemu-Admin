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

  alias QemuAdmin.{Qemu, Vm, VmServer, VmSupervisor}

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
      spawn_tool(exe, args, Vm.dir(vm))
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, :no_qemu} -> {:error, "QEMU não encontrado: veja a página QEMU"}
      _ -> {:error, "não é uma ferramenta do QEMU"}
    end
  end

  defp find("qemu-system-" <> arch), do: Qemu.system_exe(arch)
  defp find(name), do: Qemu.exe(name)

  defp spawn_tool(exe, args, dir) do
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

  @doc """
  What the Terminal does with a line typed (or a step of a saved command):
  everything it prints, sends and answers goes to the history (`log/3`). `:ok`,
  or `:error` when it failed — a tool that exits with a code other than 0, a
  command QEMU refused, a monitor or QMP command with the VM off.
  """
  def execute(%Vm{} = vm, input, src \\ "digitado") do
    input = String.trim(input)

    case parse(input) do
      {:qmp, rest} ->
        case qmp_message(rest) do
          {:ok, json} -> monitor(vm, json, rest, src, "QMP", [])
          {:error, msg} -> fail(vm, rest, src, "QMP", msg)
        end

      {:hmp, rest} ->
        monitor(vm, rest, rest, src, "monitor (HMP)", mode: :hmp)

      {:cli, rest} ->
        case route(rest) do
          {:tool, _name} ->
            tool(vm, rest, src)

          {:error, msg} ->
            fail(vm, rest, src, "linha de comando", msg)

          :monitor ->
            fail(
              vm,
              rest,
              src,
              "linha de comando",
              "cli: só roda as ferramentas do QEMU (qemu-img, qemu-io, qemu-system-* -machine help…)"
            )
        end

      {:auto, line} ->
        case route(line) do
          {:tool, _name} -> tool(vm, line, src)
          {:error, msg} -> fail(vm, line, src, "linha de comando", msg)
          :monitor -> monitor(vm, line, line, src, nil, [])
        end
    end
  end

  # `qmp: …`, `hmp: …` and `cli: …` say how a line goes to QEMU; anything else is routed by what it is
  defp parse("qmp:" <> rest), do: {:qmp, String.trim(rest)}
  defp parse("hmp:" <> rest), do: {:hmp, String.trim(rest)}
  defp parse("cli:" <> rest), do: {:cli, String.trim(rest)}
  defp parse(line), do: {:auto, line}

  @doc """
  The QMP message a `qmp:` step says: a whole message (`{"execute": "stop"}`) or
  a command name with optional arguments as a JSON object (`block_resize {"device": "d0", "size": 1048576}`).
  `{:ok, json}` or `{:error, message}`.
  """
  def qmp_message(text) do
    case String.trim(text) do
      "" ->
        {:error, "qmp: espera um comando (stop) ou uma mensagem ({\"execute\": \"stop\"})"}

      "{" <> _ = json ->
        {:ok, json}

      text ->
        {name, args} =
          case String.split(text, ~r/\s+/, parts: 2) do
            [name] -> {name, nil}
            [name, args] -> {name, args}
          end

        cond do
          not Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*$/, name) ->
            {:error, "qmp: #{name} não é um nome de comando QMP"}

          is_nil(args) ->
            {:ok, Jason.encode!(%{execute: name})}

          true ->
            case Jason.decode(args) do
              {:ok, %{} = a} -> {:ok, Jason.encode!(%{execute: name, arguments: a})}
              _ -> {:error, "qmp: os argumentos de #{name} devem ser um objeto JSON ({\"device\": \"d0\"})"}
            end
        end
    end
  end

  # a QEMU tool: the entry shows the process that really runs
  defp tool(vm, input, src) do
    x = begin(vm.id, input, src, "linha de comando")
    log(vm.id, "tool", process_text(vm, input), x)

    case run(vm, input) do
      {:ok, output, status} ->
        log(vm.id, "received", if(output == "", do: "(sem saída)", else: output), x)

        if status == 0 do
          :ok
        else
          log(vm.id, "error", "saiu com o código #{status}", x)
          :error
        end

      {:error, msg} ->
        log(vm.id, "error", msg, x)
        :error
    end
  end

  # `"C:\…\qemu-img.exe" info disk.qcow2` and where it runs
  defp process_text(vm, input) do
    with {:tool, name} <- route(input),
         {:ok, [_ | args]} <- Vm.split_args(input),
         {:ok, exe} <- find(name) do
      "#{QemuAdmin.Vm.Args.command_line(exe, args)}\n(na pasta da VM: #{Vm.dir(vm)})"
    else
      _ -> input
    end
  end

  # a monitor or QMP command (`json_or_line`), which needs the VM running
  defp monitor(vm, json_or_line, label, src, via, opts) do
    if VmSupervisor.running?(vm.id) do
      # the VmServer opens the entry, logs what it sends, the answer and the events
      meta = Keyword.merge([src: src, label: label], opts) ++ if(via, do: [via: via], else: [])

      case VmServer.console(vm.id, json_or_line, meta) do
        {:ok, _} -> :ok
        _ -> :error
      end
    else
      fail(
        vm,
        label,
        src,
        via || "monitor / QMP",
        "a VM está desligada: os comandos do monitor e do QMP só valem com ela ligada. " <>
          "Já dá para usar qemu-img, qemu-io e qemu-system-* -machine help (-cpu help, -version…)."
      )
    end
  end

  # a line that was not sent: its entry and why
  defp fail(vm, label, src, via, msg) do
    x = begin(vm.id, label, src, via)
    log(vm.id, "error", msg, x)
    :error
  end

  # ------------------------------------------------------------- history

  @doc """
  Opens an entry of the VM's history: a `"cmd"` line (what the user sees as the
  command, `src` where it came from, `via` how it reaches QEMU) that the lines
  logged with its `x` belong to. Returns that `x`.
  """
  def begin(id, label, src, via) do
    case VmServer.log_command(id, "cmd", label, %{src: src, via: via}) do
      {:ok, seq} -> seq
      {:error, :not_running} -> append(id, "cmd", label, %{src: src, via: via})
    end
  end

  @doc """
  Adds a line (`dir`: `"tool"`, `"received"`, `"error"`, `"macro"`…) to the VM's
  history, as part of the entry `x` (see `begin/4`) or alone, and broadcasts it
  as `{:vm_cmd, id, entry}`. Returns the line's `seq`.
  """
  def log(id, dir, text, x \\ nil) do
    meta = if x, do: %{x: x}, else: %{}

    case VmServer.log_command(id, dir, text, meta) do
      {:ok, seq} -> seq
      {:error, :not_running} -> append(id, dir, text, meta)
    end
  end

  # the VM is off: the file is the history
  defp append(id, dir, text, meta) do
    last = VmServer.commands(id) |> List.last()
    seq = if last, do: last.seq + 1, else: 1
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    entry = %{seq: seq, at: at, dir: dir, text: text} |> Map.merge(meta)
    entry = if dir == "cmd", do: Map.put_new(entry, :x, seq), else: entry
    path = VmServer.commands_path(id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode_to_iodata!(entry), "\n"], [:append])
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), {:vm_cmd, id, entry})
    seq
  end
end
