defmodule QemuAdmin.RenodeServer do
  @moduledoc """
  One running Renode VM (`QemuAdmin.Renode`): the Renode process (an Erlang port, its
  output kept in `qemu.log` and a ring buffer, like `QemuAdmin.VmServer`'s), its
  **monitor** (Renode's command line, on a loopback port) and the board's **UART**
  (served on another one).

  It stands where a `VmServer` stands: registered by VM id in `QemuAdmin.Registry`,
  answering the same calls (`log`, `serial_buffer`, `serial_write`, `command_line`,
  `commands`, `kill`…) and broadcasting the same messages on `QemuAdmin.topic/0`
  (`{:vm_status, id, status}`, `{:vm_log, id, line}`, `{:vm_serial, id, offset,
  bytes}`, `{:vm_cmd, id, entry}`), so the page does not tell them apart.

  The board does not run until the UART is connected: the script (`run.resc`) only
  builds the machine, and the server sends `start` to the monitor once both ports
  answer, so nothing the firmware prints at boot is lost.

  The QMP calls the page's buttons make are translated to the monitor
  (`system_powerdown`/`quit` → `quit`, `stop` → `pause`, `cont` → `start`,
  `system_reset` → `machine Reset`); any other QMP command is refused: Renode has
  none. What is typed as a monitor command goes to Renode's monitor as it is.
  """

  use GenServer, restart: :temporary, shutdown: 10_000


  alias QemuAdmin.{Firmwares, Renode, Vm, VmServer, VmSupervisor}

  @log_lines 1_000
  @attempts 80
  @serial_keep 262_144
  @cmd_keep 500

  # the QMP commands the page's buttons send, in Renode's words
  @translate %{
    "system_powerdown" => "quit",
    "quit" => "quit",
    "stop" => "pause",
    "cont" => "start",
    "system_reset" => "machine Reset"
  }

  def start_link({vm, exe}),
    do: GenServer.start_link(__MODULE__, {vm, exe}, name: {:via, Registry, {QemuAdmin.Registry, vm.id}})

  # ----------------------------------------------------------- callbacks

  @impl true
  def init({%Vm{} = vm, exe}) do
    Process.flag(:trap_exit, true)
    Logger.metadata(vm: vm.id)

    ports = alloc_ports()
    program = Firmwares.path(vm)
    File.mkdir_p!(Vm.dir(vm))
    File.write!(Renode.script_path(vm), Renode.script(vm, ports, program))

    args = Renode.args(vm, ports)
    command = QemuAdmin.Vm.Args.command_line(exe, args)

    {:ok, io} = File.open(VmServer.log_path(vm.id), [:write, :binary])
    old = commands_file(vm.id)
    File.write!(VmServer.commands_path(vm.id), Enum.map(old, &[Jason.encode_to_iodata!(&1), "\n"]))
    {:ok, cmd_io} = File.open(VmServer.commands_path(vm.id), [:append, :binary])
    serial_io = elem(File.open(VmServer.serial_path(vm.id), [:write, :binary]), 1)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:line, 8_192},
        {:args, args},
        {:cd, Vm.dir(vm)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    state =
      %{
        vm: vm,
        port: port,
        os_pid: os_pid,
        ports: ports,
        command: command,
        program: program,
        io: io,
        log: :queue.new(),
        log_size: 0,
        partial: "",
        status: :starting,
        started_at: DateTime.utc_now(),
        serial: nil,
        monitor: nil,
        attempts: 0,
        mon_buf: "",
        started?: false,
        serial_io: serial_io,
        serial_buf: "",
        serial_total: 0,
        cmd_io: cmd_io,
        cmds: :queue.from_list(old),
        cmd_seq: if(old == [], do: 0, else: List.last(old).seq),
        last_x: nil
      }
      |> add_log("# #{DateTime.utc_now() |> DateTime.truncate(:second)}")
      |> add_log("# #{command}")
      |> log_cmd("launch", command)

    publish(state)
    Process.send_after(self(), :connect, 300)
    {:ok, state}
  end

  @impl true
  def handle_call({:qmp, cmd, _args, meta}, _from, state) do
    case Map.fetch(@translate, cmd) do
      {:ok, line} ->
        {state, x} = open_exchange(state, meta, cmd, "monitor (Renode)")
        {result, state} = send_monitor(state, line, x)
        {:reply, result, state}

      :error ->
        msg = "o Renode não tem o comando QMP #{cmd}; use um comando do monitor do Renode"
        {state, x} = open_exchange(state, meta, cmd, "QMP")
        {:reply, {:error, msg}, log_cmd(state, "error", msg, %{x: x})}
    end
  end

  def handle_call({:hmp, line, meta}, _from, state) do
    {state, x} = open_exchange(state, Map.put_new(meta, :label, line), line, "monitor (Renode)")
    {result, state} = send_monitor(state, line, x)
    {:reply, result, state}
  end

  def handle_call(:commands, _from, state), do: {:reply, :queue.to_list(state.cmds), state}

  def handle_call(:clear_commands, _from, state) do
    File.close(state.cmd_io)
    File.write(VmServer.commands_path(state.vm.id), "")
    {:ok, io} = File.open(VmServer.commands_path(state.vm.id), [:append, :binary])
    {:reply, :ok, %{state | cmd_io: io, cmds: :queue.new(), last_x: nil}}
  end

  def handle_call({:log_cmd, dir, text, meta}, _from, state) do
    state = log_cmd(state, dir, text, meta)
    {:reply, {:ok, state.cmd_seq}, state}
  end

  def handle_call(:log, _from, state), do: {:reply, :queue.to_list(state.log), state}
  def handle_call(:command_line, _from, state), do: {:reply, state.command, state}

  def handle_call(:serial_buffer, _from, state),
    do: {:reply, {state.serial_buf, state.serial_total}, state}

  def handle_call({:serial_write, _data}, _from, %{serial: nil} = state),
    do: {:reply, {:error, "serial não conectada"}, state}

  def handle_call({:serial_write, data}, _from, state),
    do: {:reply, :gen_tcp.send(state.serial, data), state}

  def handle_call(:kill, _from, state) do
    os_kill(state.os_pid)
    {:reply, :ok, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, "não existe no Renode"}, state}

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    {:noreply, add_log(%{state | partial: ""}, state.partial <> chunk)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | partial: state.partial <> chunk}}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = add_log(state, "# Renode terminou (código #{code})")
    tail = state.log |> :queue.to_list() |> Enum.take(-15)

    VmSupervisor.put_runtime(state.vm.id, %{
      status: :stopped,
      exit_code: code,
      tail: tail,
      stopped_at: DateTime.utc_now(),
      screen_rev: 0
    })

    broadcast({:vm_status, state.vm.id, :stopped})
    {:stop, :normal, %{state | status: :stopped, port: nil}}
  end

  # waits for the UART and the monitor, then starts the machine
  def handle_info(:connect, %{started?: true} = state), do: {:noreply, state}

  def handle_info(:connect, state) do
    state = connect(state, :serial, [:binary, active: true, nodelay: true])
    state = connect(state, :monitor, [:binary, active: true, nodelay: true])

    cond do
      state.serial && state.monitor ->
        state = log_cmd(state, "sent", "start", %{src: "app", via: "monitor (Renode)"})
        :gen_tcp.send(state.monitor, "start\n")
        state = add_log(state, "# máquina iniciada")
        {:noreply, set_status(%{state | started?: true}, :running)}

      state.attempts < @attempts and state.port ->
        Process.send_after(self(), :connect, 250)
        {:noreply, %{state | attempts: state.attempts + 1}}

      true ->
        # the script failed (a wrong path, a board without that UART): nothing will come up
        os_kill(state.os_pid)
        {:noreply, add_log(state, "# UART ou monitor do Renode indisponível: veja o Log acima; o Renode foi encerrado")}
    end
  end

  def handle_info({:tcp, socket, data}, %{serial: socket} = state) do
    IO.binwrite(state.serial_io, data)
    broadcast({:vm_serial, state.vm.id, state.serial_total, data})

    {:noreply,
     %{
       state
       | serial_buf: tail(state.serial_buf <> data),
         serial_total: state.serial_total + byte_size(data)
     }}
  end

  # What the monitor answers comes in pieces (a character at a time, sometimes): the
  # complete lines go to the history as the "resposta" of the last command, else to the log.
  def handle_info({:tcp, socket, data}, %{monitor: socket} = state) do
    lines = (state.mon_buf <> data) |> String.split("
")
    {rest, complete} = List.pop_at(lines, -1)

    state =
      Enum.reduce(complete, %{state | mon_buf: rest}, fn line, state ->
        case line |> clean() |> monitor_line() do
          "" -> state
          text when state.last_x != nil -> log_cmd(state, "received", text, %{x: state.last_x})
          text -> add_log(state, text)
        end
      end)

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{serial: socket} = state), do: {:noreply, %{state | serial: nil}}
  def handle_info({:tcp_closed, socket}, %{monitor: socket} = state), do: {:noreply, %{state | monitor: nil}}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------- helpers

  defp connect(state, key, opts) do
    if Map.fetch!(state, key) do
      state
    else
      port = Map.fetch!(state.ports, key)

      case :gen_tcp.connect({127, 0, 0, 1}, port, opts, 500) do
        {:ok, socket} -> Map.put(state, key, socket)
        {:error, _} -> state
      end
    end
  end

  # A command to the monitor: its answer comes back asynchronously, on its socket.
  defp send_monitor(%{monitor: nil} = state, _line, x) do
    msg = "o monitor do Renode ainda não conectou"
    {{:error, msg}, log_cmd(state, "error", msg, %{x: x})}
  end

  defp send_monitor(state, line, x) do
    state = log_cmd(state, "sent", line, %{x: x})
    :gen_tcp.send(state.monitor, line <> "\n")

    state =
      case line do
        "pause" -> set_status(state, :paused)
        "start" -> set_status(state, :running)
        "quit" -> set_status(state, :stopping)
        _ -> state
      end

    {{:ok, "(enviado ao monitor do Renode)"}, %{state | last_x: x}}
  end

  # The history entry that opens a command, and the x that ties what follows to it.
  defp open_exchange(state, meta, cmd, via) do
    state = log_cmd(state, "cmd", meta[:label] || cmd, %{src: meta[:src] || "app", via: via})
    {state, state.cmd_seq}
  end

  # Renode's monitor speaks telnet: its negotiation bytes and colours are not the answer.
  defp clean(data) do
    data
    |> String.replace(~r/\xFF[\xFB-\xFE]./s, "")
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> String.replace("\r", "")
    |> utf8()
  end

  # a line of the monitor without its prompt: `(monitor) ` or `(Renode STM32F4) `
  defp monitor_line(line) do
    line |> String.replace(~r/^(\([^()\n]*\)\s*)+/, "") |> String.trim()
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    state = %{state | status: status}
    publish(state)
    state
  end

  defp publish(state) do
    VmSupervisor.put_runtime(state.vm.id, %{
      status: state.status,
      pid: self(),
      os_pid: state.os_pid,
      ports: state.ports,
      started_at: state.started_at,
      display: "none",
      screen_rev: 0
    })

    broadcast({:vm_status, state.vm.id, state.status})
  end

  defp log_cmd(state, dir, text, meta \\ %{}) do
    seq = state.cmd_seq + 1
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    entry =
      %{seq: seq, at: at, dir: dir, text: utf8(text)}
      |> Map.merge(for {k, v} <- meta, k in [:x, :src, :via], v != nil, into: %{}, do: {k, v})
      |> then(&if dir == "cmd", do: Map.put_new(&1, :x, seq), else: &1)

    IO.binwrite(state.cmd_io, [Jason.encode_to_iodata!(entry), "\n"])
    broadcast({:vm_cmd, state.vm.id, entry})

    cmds = :queue.in(entry, state.cmds)
    cmds = if :queue.len(cmds) > @cmd_keep, do: :queue.drop(cmds), else: cmds
    %{state | cmds: cmds, cmd_seq: seq}
  end

  defp commands_file(id) do
    case File.read(VmServer.commands_path(id)) do
      {:ok, text} ->
        text
        |> String.split(~r/\R/, trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"seq" => seq, "at" => at, "dir" => dir, "text" => t} = e} ->
              extra = for k <- ~w(x src via), is_map_key(e, k), into: %{}, do: {String.to_existing_atom(k), e[k]}
              [Map.merge(%{seq: seq, at: at, dir: dir, text: t}, extra)]

            _ ->
              []
          end
        end)
        |> Enum.take(-@cmd_keep)

      _ ->
        []
    end
  end

  defp utf8(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text, "?")
  end

  defp add_log(state, line) do
    line = if String.valid?(line), do: line, else: :unicode.characters_to_binary(line, :latin1)
    IO.binwrite(state.io, line <> "\n")
    broadcast({:vm_log, state.vm.id, line})
    log = :queue.in(line, state.log)

    if state.log_size >= @log_lines,
      do: %{state | log: :queue.drop(log)},
      else: %{state | log: log, log_size: state.log_size + 1}
  end

  defp tail(data) when byte_size(data) > @serial_keep,
    do: binary_part(data, byte_size(data) - @serial_keep, @serial_keep)

  defp tail(data), do: data

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), msg)

  # The UART and the monitor on any free port, apart from the ones other VMs hold.
  defp alloc_ports do
    taken = MapSet.new(VmSupervisor.ports_in_use())
    serial = free_port(taken)
    monitor = free_port(MapSet.put(taken, serial))
    %{serial: serial, monitor: monitor}
  end

  defp free_port(taken) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    if port in taken, do: free_port(taken), else: port
  end

  defp os_kill(nil), do: :ok

  defp os_kill(os_pid) do
    case :os.type() do
      {:win32, _} -> System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)
      _ -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end
end
