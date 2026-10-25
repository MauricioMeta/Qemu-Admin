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

  What was sent to QEMU is kept as a **command history** (`commands/1`,
  `commands.log` in the VM's folder, one JSON object per line, the last 500 of
  them, kept from one run to the next): the command line each run started with, every QMP command a user action sent and its
  answer, the QMP events, and what was typed in the page's command panel
  (`console/2`: a QMP JSON message, or a monitor command such as
  `info registers`, which goes through `human-monitor-command`). The
  screenshots and the state queries the server makes by itself are left out.

  Every change goes out on `QemuAdmin.topic/0`:
  `{:vm_status, id, status}`, `{:vm_log, id, line}`, `{:vm_screen, id, rev}`,
  `{:vm_cmd, id, entry}` (an entry of the command history),
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
  @cmd_keep 500

  # ---------------------------------------------------------------- API

  def start_link({vm, exe}), do: GenServer.start_link(__MODULE__, {vm, exe}, name: via(vm.id))

  defp via(id), do: {:via, Registry, {QemuAdmin.Registry, id}}

  @doc "ACPI power button: the guest shuts itself down."
  def powerdown(id), do: qmp(id, "system_powerdown", %{}, src: "botão", label: "Desligar (botão de energia)")
  def reset(id), do: qmp(id, "system_reset", %{}, src: "botão", label: "Reiniciar")
  def pause(id), do: qmp(id, "stop", %{}, src: "botão", label: "Pausar")
  def resume(id), do: qmp(id, "cont", %{}, src: "botão", label: "Retomar")
  @doc "Ends QEMU at once (pulling the plug, but QEMU flushes the disks)."
  def quit(id), do: qmp(id, "quit", %{}, src: "botão", label: "Encerrar agora")

  @doc "Inserts `path` in the VM's CD drive."
  def change_cdrom(id, path),
    do:
      qmp(id, "blockdev-change-medium", %{id: "cd0", filename: path, format: "raw"},
        src: "app",
        label: "Trocar o CD"
      )

  def eject(id), do: qmp(id, "eject", %{id: "cd0", force: true}, src: "app", label: "Ejetar o CD")

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

  @doc """
  Sends a QMP command: `{:ok, return}` or `{:error, reason}`. `meta` says where
  it comes from, for the history: `:src` (`"botão"`, `"digitado"`, `"app"`…),
  `:label` (what the user sees as the command; the QMP name by default) and
  `:silent` (not logged: the app's own polling).
  """
  def qmp(id, command, args \\ %{}, meta \\ []), do: call(id, {:qmp, command, args, Map.new(meta)})

  @doc """
  What the user typed in the command panel: a QMP message as JSON
  (`{"execute": "query-status"}`, with optional `"arguments"`) or a monitor
  (HMP) command (`info registers`). `{:ok, answer}` or `{:error, reason}`;
  the answer is in the history too. `meta` as in `qmp/4`, plus `mode: :hmp` to
  make a line that starts with `{` a monitor command anyway.
  """
  def console(id, input, meta \\ []) do
    meta = Map.new(meta)

    result =
      case {meta[:mode], String.trim(input)} do
        {_, ""} ->
          {:invalid, "comando vazio"}

        {mode, "{" <> _ = json} when mode != :hmp ->
          case Jason.decode(json) do
            {:ok, %{"execute" => cmd} = msg} when is_binary(cmd) ->
              case Map.get(msg, "arguments", %{}) do
                args when is_map(args) ->
                  qmp(id, cmd, args, Map.put_new(meta, :label, String.trim(json)))

                _ ->
                  {:invalid, ~s("arguments" deve ser um objeto)}
              end

            _ ->
              {:invalid, ~s(JSON QMP inválido; use {"execute": "query-status"})}
          end

        {_, line} ->
          call(id, {:hmp, line, meta})
      end

    # what the VM answered with an error is in the history already; what was
    # wrong with the input was never sent, so it is logged here
    case result do
      {:invalid, msg} ->
        x = header(id, input, meta[:src] || "digitado", "QMP")
        _ = log_command(id, "error", msg, %{x: x})
        {:error, msg}

      other ->
        other
    end
  end

  # The line that opens an entry of the history: `{:ok, seq}` is the x of what follows.
  defp header(id, label, src, via) do
    case log_command(id, "cmd", label, %{src: src, via: via}) do
      {:ok, seq} -> seq
      _ -> nil
    end
  end

  @doc """
  The command history, oldest first: `%{seq:, at:, dir:, text:}` with `dir`
  `"launch"`, `"cmd"`, `"sent"`, `"received"`, `"event"` or `"error"`, and, for
  what belongs to a command, `x` (the `seq` of its `"cmd"` line), `src` (where it
  came from) and `via` (how it reached QEMU). From `commands.log` when the VM is
  not running.
  """
  def commands(id) do
    case call(id, :commands) do
      {:error, :not_running} -> commands_file(id)
      list -> list
    end
  end

  @doc """
  Adds an entry to the history of the run (`QemuAdmin.Terminal.log/3` does it
  for a VM that is off): `{:ok, seq}` or `{:error, :not_running}`. `meta`: `x`,
  `src` and `via` (see `commands/1`); a `"cmd"` line is its own `x`.
  """
  def log_command(id, dir, text, meta \\ %{}), do: call(id, {:log_cmd, dir, text, meta}) |> only_ok()

  defp only_ok({:ok, seq}), do: {:ok, seq}
  defp only_ok(_), do: {:error, :not_running}

  def commands_path(id), do: Path.join(QemuAdmin.Paths.vm_dir(id), "commands.log")

  defp commands_file(id) do
    case File.read(commands_path(id)) do
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
    args = Args.build_run(vm, ports)
    command = Args.command_line(exe, args)

    File.mkdir_p!(Vm.dir(vm))
    {:ok, io} = File.open(log_path(vm.id), [:write, :binary])
    # the history goes on from the last run (and from what was typed with the VM
    # off, a saved command's `@start` among it): the file is kept, cut to the last entries
    old = commands_file(vm.id)

    File.write!(
      commands_path(vm.id),
      Enum.map(old, &[Jason.encode_to_iodata!(&1), "\n"])
    )

    {:ok, cmd_io} = File.open(commands_path(vm.id), [:append, :binary])

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
      # QMP id → the history entry (x) a user's command opened, for its answer
      xs: %{},
      # the last command's x and when it was sent: the events right after are its
      last_x: nil,
      last_x_at: 0,
      screen_rev: 0,
      board?: board?,
      gdb?: is_integer(Map.get(ports, :gdb)),
      gpio: gpio,
      serial: nil,
      serial_attempts: 0,
      serial_io: serial_io,
      serial_buf: "",
      serial_total: 0,
      cmd_io: cmd_io,
      cmds: :queue.from_list(old),
      cmd_seq: if(old == [], do: 0, else: List.last(old).seq)
    }

    state =
      state
      |> add_log("# #{DateTime.utc_now() |> DateTime.truncate(:second)}")
      |> add_log("# #{command}")
      |> log_cmd("launch", command)

    publish(state)
    Process.send_after(self(), :qmp_connect, 150)
    if serial?, do: Process.send_after(self(), :serial_connect, 100)
    {:ok, state}
  end

  @impl true
  def handle_call({:qmp, cmd, _args, meta}, _from, %{qmp_ready: false} = state) do
    msg = "QMP ainda não conectado"
    {state, x} = begin_exchange(state, meta, cmd, "QMP")
    {:reply, {:error, msg}, log_cmd(state, "error", msg, %{x: x})}
  end

  # with the gdbstub attached, it holds and releases the CPUs
  def handle_call({:qmp, cmd, _args, meta}, _from, %{gdb?: true} = state)
      when cmd in ["stop", "cont"] do
    {state, x} = begin_exchange(state, meta, cmd, "gdbstub")

    state =
      log_cmd(state, "sent", "(gdbstub) #{if cmd == "stop", do: "interromper a CPU", else: "continuar a CPU"}: não passa pelo QMP", %{x: x})

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

  def handle_call({:qmp, cmd, args, meta}, from, state) do
    # A board has no ACPI: its power button is the plug.
    cmd = if cmd == "system_powerdown" and state.board?, do: "quit", else: cmd
    state = if cmd == "quit" or cmd == "system_powerdown", do: stopping(state, cmd), else: state
    {state, x} = begin_exchange(state, meta, cmd, "QMP")
    {:noreply, send_qmp(state, cmd, args, from, x)}
  end

  def handle_call({:hmp, line, meta}, _from, %{qmp_ready: false} = state) do
    msg = "QMP ainda não conectado"
    {state, x} = begin_exchange(state, Map.put_new(meta, :label, line), line, "monitor (HMP)")
    {:reply, {:error, msg}, log_cmd(state, "error", msg, %{x: x})}
  end

  def handle_call({:hmp, line, meta}, from, state) do
    {state, x} = begin_exchange(state, Map.put_new(meta, :label, line), line, "monitor (HMP)")
    {:noreply, send_qmp(state, "human-monitor-command", %{"command-line" => line}, from, x)}
  end

  def handle_call(:commands, _from, state), do: {:reply, :queue.to_list(state.cmds), state}

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
    File.close(state.cmd_io)
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

  # `x`: the history entry of the user's command this is (nil for the app's own
  # chatter — the handshake, the status, the screen — which is not logged).
  # What is logged is the line that goes down the socket, `id` and all.
  defp send_qmp(state, cmd, args, from, x \\ nil) do
    id = state.next_id
    msg = %{execute: cmd, id: id}
    msg = if args == %{}, do: msg, else: Map.put(msg, :arguments, args)
    wire = Jason.encode!(msg)
    :gen_tcp.send(state.qmp, [wire, "\r\n"])
    state = if x, do: log_cmd(state, "sent", wire, %{x: x}), else: state
    xs = if x, do: Map.put(state.xs, id, x), else: state.xs
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, from), xs: xs}
  end

  # A user's command opens an entry of the history (a `"cmd"` line: what the user
  # sees, where it came from, how it reaches QEMU) that its wire message, answer
  # and events hang from. `{state, x}`; x is nil when the command is `silent`.
  defp begin_exchange(state, %{silent: true}, _label, _via), do: {state, nil}

  defp begin_exchange(state, meta, label, via) do
    x = state.cmd_seq + 1
    head = %{x: x, src: meta[:src] || "app", via: meta[:via] || via}
    state = log_cmd(state, "cmd", meta[:label] || label, head)
    {%{state | last_x: x, last_x_at: System.monotonic_time(:millisecond)}, x}
  end

  defp qmp_message(state, %{"QMP" => _greeting}) do
    send_qmp(state, "qmp_capabilities", %{}, :capabilities)
  end

  defp qmp_message(state, %{"return" => ret, "id" => id} = msg) do
    {from, pending} = Map.pop(state.pending, id)
    {x, xs} = Map.pop(state.xs, id)
    state = %{state | pending: pending, xs: xs}
    if is_tuple(from), do: reply_user(state, from, {:ok, ret}, x, msg), else: reply(state, from, {:ok, ret})
  end

  defp qmp_message(state, %{"error" => err, "id" => id} = msg) do
    {from, pending} = Map.pop(state.pending, id)
    {x, xs} = Map.pop(state.xs, id)
    state = %{state | pending: pending, xs: xs}
    result = {:error, err["desc"] || inspect(err)}
    if is_tuple(from), do: reply_user(state, from, result, x, msg), else: reply(state, from, result)
  end

  defp qmp_message(state, %{"event" => event} = msg) do
    # the gdbstub's own stops and resumes are not the user's (see the moduledoc)
    state =
      if state.gdb? and event in ["STOP", "RESUME"],
        do: state,
        else: log_cmd(state, "event", event_text(msg), %{x: recent_x(state)})

    qmp_event(state, event, msg)
  end
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

  defp reply(state, _internal, _result), do: state

  # The answer to a user's command goes to the history under its entry: the
  # whole message QEMU sent for a QMP command, the monitor's text for a
  # monitor one (QMP carries it as a string).
  defp reply_user(state, from, result, nil, _msg) do
    GenServer.reply(from, result)
    state
  end

  defp reply_user(state, from, result, x, msg) do
    GenServer.reply(from, result)
    meta = %{x: x}

    case result do
      {:ok, text} when is_binary(text) ->
        log_cmd(state, "received", String.trim_trailing(text), meta)

      {:ok, _ret} ->
        log_cmd(state, "received", Jason.encode!(msg), meta)

      {:error, desc} ->
        state
        |> log_cmd("received", Jason.encode!(msg), meta)
        |> log_cmd("error", to_string(desc), meta)
    end
  end

  # events within 1.5 s of a command belong to it (STOP after `stop`…)
  defp recent_x(%{last_x: x, last_x_at: at}) when is_integer(x) do
    if System.monotonic_time(:millisecond) - at <= 1_500, do: x
  end

  defp recent_x(_state), do: nil

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

  defp event_text(%{"event" => event} = msg) do
    case msg["data"] do
      data when is_map(data) and data != %{} -> "#{event} #{Jason.encode!(data)}"
      _ -> event
    end
  end

  # One entry of the command history: kept (the last @cmd_keep), written to
  # commands.log and broadcast. `text` may be long and have lines (an HMP answer).
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

  defp utf8(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text, "?")
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
