defmodule QemuAdmin.VmServer do
  @moduledoc """
  One running VM: the QEMU process (an Erlang port, its output read line by
  line into `qemu.log` and a ring buffer) and its **QMP** socket — QEMU's
  JSON control protocol on a loopback port, through which the page powers
  the VM down, resets, pauses, swaps the CD and takes the screenshots shown
  in the VM list.

  Started by `QemuAdmin.VmSupervisor.start_vm/1`, registered by VM id in
  `QemuAdmin.Registry`. It exits when QEMU does; how the run ended (exit
  code, last lines) stays in the runtime table for the page.

  A development board (`Vm.serial?/1`) has a **UART**: QEMU serves it on
  another loopback port and waits for this process to connect before the
  board boots. What it prints is kept (the last 256 KiB, and
  `serial.log`) and broadcast; `serial_write/2` types into it. Its pins are
  followed by a `QemuAdmin.Gpio` started here; on an ESP32 or an Arduino
  that goes through QEMU's gdbstub, which then owns the run state: pause
  and resume go through it, and the QMP events every watchpoint causes
  (STOP, RESUME) are not the user's.

  Every change goes out on `QemuAdmin.topic/0`:
  `{:vm_status, id, status}`, `{:vm_log, id, line}`, `{:vm_screen, id, rev}`,
  `{:vm_serial, id, offset, bytes}` (`offset`: where `bytes` start in the
  run's whole output, so a page that just loaded the buffer drops what it
  already has).
  Statuses: `:starting`, `:running`, `:paused`, `:stopping`, `:stopped`.
  """

  use GenServer, restart: :temporary, shutdown: 10_000

  require Logger

  alias QemuAdmin.{Vm, VmSupervisor}
  alias QemuAdmin.Vm.Args

  @log_lines 1_000
  @screen_every 5_000
  @qmp_attempts 60
  @serial_keep 262_144

  # ---------------------------------------------------------------- API

  def start_link({vm, exe}), do: GenServer.start_link(__MODULE__, {vm, exe}, name: via(vm.id))

  defp via(id), do: {:via, Registry, {QemuAdmin.Registry, id}}

  @doc "ACPI power button: the guest shuts itself down."
  def powerdown(id), do: qmp(id, "system_powerdown")
  def reset(id), do: qmp(id, "system_reset")
  def pause(id), do: qmp(id, "stop")
  def resume(id), do: qmp(id, "cont")
  @doc "Ends QEMU at once (pulling the plug, but QEMU flushes the disks)."
  def quit(id), do: qmp(id, "quit")

  @doc "Inserts `path` in the VM's CD drive."
  def change_cdrom(id, path),
    do: qmp(id, "blockdev-change-medium", %{id: "cd0", filename: path, format: "raw"})

  def eject(id), do: qmp(id, "eject", %{id: "cd0", force: true})

  @doc "Kills the QEMU process (when QMP no longer answers)."
  def kill(id), do: call(id, :kill)

  @doc "The last lines QEMU printed (the log file when it is not running)."
  def log(id) do
    case call(id, :log) do
      {:error, :not_running} -> log_file_tail(id)
      lines -> lines
    end
  end

  @doc """
  The UART's output so far: `{bytes, total}`, `total` being how many bytes
  the run printed (`bytes` is the tail). From `serial.log` when the VM is off.
  """
  def serial_buffer(id) do
    case call(id, :serial_buffer) do
      {:error, :not_running} ->
        case File.read(serial_path(id)) do
          {:ok, data} -> {tail(data), byte_size(data)}
          _ -> {"", 0}
        end

      result ->
        result
    end
  end

  @doc "Types `data` into the UART."
  def serial_write(id, data), do: call(id, {:serial_write, data})

  def serial_path(id), do: Path.join(QemuAdmin.Paths.vm_dir(id), "serial.log")

  defp tail(data) when byte_size(data) > @serial_keep,
    do: binary_part(data, byte_size(data) - @serial_keep, @serial_keep)

  defp tail(data), do: data

  @doc "The command line of the current run."
  def command_line(id), do: call(id, :command_line)

  @doc "Sends a QMP command: `{:ok, return}` or `{:error, reason}`."
  def qmp(id, command, args \\ %{}), do: call(id, {:qmp, command, args})

  defp call(id, msg) do
    GenServer.call(via(id), msg, 15_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  def log_path(id), do: Path.join(QemuAdmin.Paths.vm_dir(id), "qemu.log")

  defp log_file_tail(id) do
    case File.read(log_path(id)) do
      {:ok, text} -> text |> String.split(~r/\R/) |> Enum.take(-@log_lines)
      _ -> []
    end
  end

  # ----------------------------------------------------------- callbacks

  @impl true
  def init({%Vm{} = vm, exe}) do
    Process.flag(:trap_exit, true)
    Logger.metadata(vm: vm.id)

    ports = alloc_ports(vm)
    args = Args.build(vm, ports)
    command = Args.command_line(exe, args)

    File.mkdir_p!(Vm.dir(vm))
    {:ok, io} = File.open(log_path(vm.id), [:write, :binary])

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # no console window flashing up on Windows
        :hide,
        {:line, 8_192},
        {:args, args},
        {:cd, Vm.dir(vm)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    board? = Vm.board(vm) != nil
    serial? = Vm.serial?(vm)
    serial_io = if serial?, do: elem(File.open(serial_path(vm.id), [:write, :binary]), 1)

    board = Vm.board(vm)

    # a board whose pins are not followed (`io: nil`, the Cortex-M ones) has no tracker
    gpio =
      if board && board.io do
        {:ok, pid} =
          QemuAdmin.Gpio.start_link(%{vm: vm, board: board, ports: ports, server: self()})

        pid
      end

    state = %{
      vm: vm,
      port: port,
      os_pid: os_pid,
      ports: ports,
      command: command,
      io: io,
      log: :queue.new(),
      log_size: 0,
      partial: "",
      status: :starting,
      started_at: DateTime.utc_now(),
      qmp: nil,
      qmp_ready: false,
      qmp_attempts: 0,
      qmp_buf: "",
      next_id: 1,
      pending: %{},
      screen_rev: 0,
      board?: board?,
      gdb?: is_integer(Map.get(ports, :gdb)),
      gpio: gpio,
      serial: nil,
      serial_attempts: 0,
      serial_io: serial_io,
      serial_buf: "",
      serial_total: 0
    }

    state =
      state
      |> add_log("# #{DateTime.utc_now() |> DateTime.truncate(:second)}")
      |> add_log("# #{command}")

    publish(state)
    Process.send_after(self(), :qmp_connect, 150)
    if serial?, do: Process.send_after(self(), :serial_connect, 100)
    {:ok, state}
  end

  @impl true
  def handle_call({:qmp, _cmd, _args}, _from, %{qmp_ready: false} = state) do
    {:reply, {:error, "QMP ainda não conectado"}, state}
  end

  # with the gdbstub attached, it holds and releases the CPUs
  def handle_call({:qmp, cmd, _args}, _from, %{gdb?: true} = state)
      when cmd in ["stop", "cont"] do
    result =
      if cmd == "stop",
        do: QemuAdmin.Gpio.pause(state.vm.id),
        else: QemuAdmin.Gpio.resume(state.vm.id)

    state =
      case result do
        {:ok, _} -> set_status(state, if(cmd == "stop", do: :paused, else: :running))
        _ -> state
      end

    {:reply, result, state}
  end

  def handle_call({:qmp, cmd, args}, from, state) do
    # A board has no ACPI: its power button is the plug.
    cmd = if cmd == "system_powerdown" and state.board?, do: "quit", else: cmd
    state = if cmd == "quit" or cmd == "system_powerdown", do: stopping(state, cmd), else: state
    {:noreply, send_qmp(state, cmd, args, from)}
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

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.partial <> chunk
    {:noreply, add_log(%{state | partial: ""}, line)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | partial: state.partial <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = add_log(state, "# QEMU terminou (código #{code})")
    tail = state.log |> :queue.to_list() |> Enum.take(-15)

    VmSupervisor.put_runtime(state.vm.id, %{
      status: :stopped,
      exit_code: code,
      tail: tail,
      stopped_at: DateTime.utc_now(),
      screen_rev: state.screen_rev
    })

    broadcast({:vm_status, state.vm.id, :stopped})
    {:stop, :normal, %{state | status: :stopped, port: nil}}
  end

  def handle_info(:qmp_connect, state) do
    opts = [:binary, packet: :line, active: true, buffer: 1_048_576, recbuf: 1_048_576]

    case :gen_tcp.connect({127, 0, 0, 1}, state.ports.qmp, opts, 1_000) do
      {:ok, socket} ->
        {:noreply, %{state | qmp: socket}}

      {:error, reason} ->
        attempts = state.qmp_attempts + 1

        if attempts < @qmp_attempts and state.port do
          Process.send_after(self(), :qmp_connect, 250)
          {:noreply, %{state | qmp_attempts: attempts}}
        else
          Logger.warning("QMP indisponível: #{inspect(reason)}")
          {:noreply, add_log(state, "# QMP indisponível (#{inspect(reason)})")}
        end
    end
  end

  def handle_info(:serial_connect, state) do
    case :gen_tcp.connect(
           {127, 0, 0, 1},
           state.ports.serial,
           [:binary, active: true, nodelay: true],
           1_000
         ) do
      {:ok, socket} ->
        {:noreply, %{state | serial: socket}}

      {:error, reason} ->
        attempts = state.serial_attempts + 1

        if attempts < @qmp_attempts and state.port do
          Process.send_after(self(), :serial_connect, 250)
          {:noreply, %{state | serial_attempts: attempts}}
        else
          {:noreply, add_log(state, "# serial indisponível (#{inspect(reason)})")}
        end
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

  def handle_info({:tcp_closed, socket}, %{serial: socket} = state),
    do: {:noreply, %{state | serial: nil}}

  def handle_info({:tcp, socket, data}, %{qmp: socket} = state) do
    buf = state.qmp_buf <> data

    if String.ends_with?(buf, "\n") do
      state = %{state | qmp_buf: ""}

      state =
        buf
        |> String.split(~r/\R/, trim: true)
        |> Enum.reduce(state, fn line, st ->
          case Jason.decode(line) do
            {:ok, msg} -> qmp_message(st, msg)
            _ -> st
          end
        end)

      {:noreply, state}
    else
      # a line longer than the socket's buffer arrives in pieces
      {:noreply, %{state | qmp_buf: buf}}
    end
  end

  def handle_info({:tcp_closed, socket}, %{qmp: socket} = state) do
    {:noreply, %{state | qmp: nil, qmp_ready: false}}
  end

  def handle_info(:screen, %{qmp_ready: true, status: :running} = state) do
    Process.send_after(self(), :screen, @screen_every)

    if state.vm.display == "none" do
      {:noreply, state}
    else
      file = Path.join(Vm.dir(state.vm), "screen.png")
      {:noreply, send_qmp(state, "screendump", %{filename: file, format: "png"}, :screen)}
    end
  end

  def handle_info(:screen, state) do
    Process.send_after(self(), :screen, @screen_every)
    {:noreply, state}
  end

  # the gdbstub never answered: let the VM run without the pins
  def handle_info({:gdb_failed, msg}, state) do
    state = add_log(%{state | gdb?: false}, "# IO da placa indisponível: #{msg}")
    {:noreply, if(state.qmp_ready, do: send_qmp(state, "cont", %{}, :cont), else: state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # The application is going down with the VM still running (the supervisor
  # stops its children): QEMU must not outlive the BEAM. `quit` first — it
  # flushes the disks — and the process is killed if it does not go.
  @impl true
  def terminate(_reason, %{port: port} = state) when not is_nil(port) do
    if state.qmp_ready do
      :gen_tcp.send(state.qmp, ~s({"execute":"quit"}\r\n))
    end

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      3_000 -> os_kill(state.os_pid)
    end

    finish(state)
  end

  def terminate(_reason, state), do: finish(state)

  defp finish(state) do
    File.close(state.io)
    if state.serial_io, do: File.close(state.serial_io)

    # gone without QEMU's exit being seen (this process crashed): the page
    # must not keep showing the VM on
    if state.status != :stopped do
      VmSupervisor.put_runtime(state.vm.id, %{status: :stopped, stopped_at: DateTime.utc_now()})
      broadcast({:vm_status, state.vm.id, :stopped})
    end

    :ok
  end

  # --------------------------------------------------------------- QMP

  defp send_qmp(state, cmd, args, from) do
    id = state.next_id
    msg = %{execute: cmd, id: id}
    msg = if args == %{}, do: msg, else: Map.put(msg, :arguments, args)
    :gen_tcp.send(state.qmp, [Jason.encode_to_iodata!(msg), "\r\n"])
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}
  end

  defp qmp_message(state, %{"QMP" => _greeting}) do
    send_qmp(state, "qmp_capabilities", %{}, :capabilities)
  end

  defp qmp_message(state, %{"return" => ret, "id" => id}) do
    {from, pending} = Map.pop(state.pending, id)
    reply(%{state | pending: pending}, from, {:ok, ret})
  end

  defp qmp_message(state, %{"error" => err, "id" => id}) do
    {from, pending} = Map.pop(state.pending, id)
    reply(%{state | pending: pending}, from, {:error, err["desc"] || inspect(err)})
  end

  defp qmp_message(state, %{"event" => event} = msg), do: qmp_event(state, event, msg)
  defp qmp_message(state, _msg), do: state

  defp reply(state, :capabilities, {:ok, _}) do
    Process.send_after(self(), :screen, 1_500)
    send_qmp(%{state | qmp_ready: true}, "query-status", %{}, :status)
  end

  # started paused (-S) for the gdbstub, which lets it run as it attaches
  defp reply(state, :status, {:ok, _}) when state.gdb?, do: set_status(state, :running)

  defp reply(state, :status, {:ok, %{"status" => status}}) do
    set_status(state, if(status == "paused", do: :paused, else: :running))
  end

  defp reply(state, :screen, {:ok, _}) do
    rev = state.screen_rev + 1
    state = %{state | screen_rev: rev}
    publish(state)
    broadcast({:vm_screen, state.vm.id, rev})
    state
  end

  defp reply(state, from, result) when is_tuple(from) do
    GenServer.reply(from, result)
    state
  end

  defp reply(state, _internal, _result), do: state

  defp qmp_event(%{gdb?: true} = state, event, _) when event in ["STOP", "RESUME"], do: state

  defp qmp_event(state, "STOP", _),
    do: if(state.status == :stopping, do: state, else: set_status(state, :paused))

  defp qmp_event(state, "RESUME", _), do: set_status(state, :running)
  defp qmp_event(state, "SHUTDOWN", _), do: set_status(state, :stopping)

  defp qmp_event(state, "POWERDOWN", _), do: add_log(state, "# botão de desligar (ACPI) enviado")
  defp qmp_event(state, "RESET", _), do: add_log(state, "# reset")
  defp qmp_event(state, _event, _msg), do: state

  defp stopping(state, "quit"), do: set_status(state, :stopping)
  defp stopping(state, _powerdown), do: state

  # ------------------------------------------------------------- helpers

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
      display: state.vm.display,
      screen_rev: state.screen_rev
    })

    broadcast({:vm_status, state.vm.id, state.status})
  end

  defp add_log(state, line) do
    # QEMU on Windows prints in the console's code page, not UTF-8 — and an
    # invalid binary would break the page's JSON.
    line = if String.valid?(line), do: line, else: :unicode.characters_to_binary(line, :latin1)
    IO.binwrite(state.io, line <> "\n")
    broadcast({:vm_log, state.vm.id, line})
    log = :queue.in(line, state.log)

    if state.log_size >= @log_lines,
      do: %{state | log: :queue.drop(log)},
      else: %{state | log: log, log_size: state.log_size + 1}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), msg)

  # QMP and the WebSocket on any free port; VNC needs one from 5900 up (its
  # "display" is the offset). Ports the other VMs hold are skipped even when
  # their QEMU has not bound them yet.
  defp alloc_ports(vm) do
    taken = MapSet.new(VmSupervisor.ports_in_use())
    qmp = free_port(taken)
    taken = MapSet.put(taken, qmp)
    ws = free_port(taken)
    taken = MapSet.put(taken, ws)
    serial = free_port(taken)
    taken = MapSet.put(taken, serial)
    vnc = Enum.find(5900..5999, &(&1 not in taken and port_free?(&1)))
    ports = %{qmp: qmp, ws: ws, vnc: vnc, serial: serial}

    # the boards whose pins are followed through the gdbstub
    if Vm.kind(vm) in [:esp32, :avr],
      do: Map.put(ports, :gdb, free_port(MapSet.put(taken, vnc))),
      else: ports
  end

  defp free_port(taken) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    if port in taken, do: free_port(taken), else: port
  end

  defp port_free?(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp os_kill(nil), do: :ok

  defp os_kill(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/PID", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end
end
