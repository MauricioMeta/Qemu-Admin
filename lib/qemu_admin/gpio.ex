defmodule QemuAdmin.Gpio do
  @moduledoc """
  A running board's pins, for the Placa view: which are outputs and at what
  level, and the levels the user sets on the inputs (a button press is a
  click on the pin).

  Started by `QemuAdmin.VmServer` with the VM, registered as `{:gpio, id}`.
  How it follows the pins depends on the board (`QemuAdmin.Board`, `io`):

    * **ESP32 and Arduino** — their emulated GPIO keeps nothing (writes are
      dropped, reads give 0), so the registers are watched through QEMU's
      gdbstub (`QemuAdmin.Gdb`): the VM starts paused, the watchpoints go in,
      and on every access the CPU stops before it; the backend
      (`QemuAdmin.Gpio.Esp32`, `QemuAdmin.Gpio.Avr`) decodes the instruction,
      keeps what a write meant, steps over it and, for a read, puts the
      register's value — the inputs included — where the program expects it.
      Pausing and resuming such a VM go through here (`pause/1`, `resume/1`):
      the gdbstub owns its run state. A backend may also want the CPU now
      and then (`tick_every/1`, `tick/2`: the Arduino's missing Timer0): it
      is interrupted for that and let go again.
    * **Raspberry Pi** — QEMU models the BCM2835's GPIO, so its registers are
      read over QMP a few times a second (`QemuAdmin.Gpio.Raspi`); its inputs
      cannot be driven from outside.

  Changes go out on `QemuAdmin.topic/0` as `{:vm_gpio, id, snapshot}`
  (at most every 50 ms), `snapshot` being what `snapshot/1` returns.
  """

  use GenServer, restart: :temporary

  require Logger

  alias QemuAdmin.{Gdb, VmServer}
  alias QemuAdmin.Gpio.{Avr, Esp32, Raspi}

  @flush 50
  @poll 250
  @attempts 80

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts.vm.id))

  defp via(id), do: {:via, Registry, {QemuAdmin.Registry, {:gpio, id}}}

  @doc """
  `%{pins: %{gpio => %{dir: :in | :out | :alt, level: 0 | 1}}, driven:,
  status:, error:, inputs?:}` or nil when the VM is not running; `driven`
  the levels set with `set_input/3`.
  """
  def snapshot(id), do: call(id, :snapshot, nil)

  @doc "Sets the level the outside world drives an input to."
  def set_input(id, gpio, level), do: call(id, {:set_input, gpio, level}, {:error, :not_running})

  def pause(id), do: call(id, :pause, {:error, :not_running})
  def resume(id), do: call(id, :resume, {:error, :not_running})

  defp call(id, msg, default) do
    GenServer.call(via(id), msg, 10_000)
  catch
    :exit, _ -> default
  end

  defp backend(:esp32), do: Esp32
  defp backend(:avr), do: Avr
  defp backend(:raspi), do: Raspi

  # ----------------------------------------------------------- callbacks

  @impl true
  def init(%{vm: vm, board: board, ports: ports, server: server}) do
    backend = backend(board.io)

    state = %{
      id: vm.id,
      board: board,
      backend: backend,
      b: backend.init(board),
      inputs: %{},
      ports: ports,
      server: server,
      conn: nil,
      tid: "01",
      hg: nil,
      status: :attaching,
      error: nil,
      attempts: 0,
      held?: false,
      pause_from: nil,
      tick: nil,
      tick_pending: false,
      flush: nil,
      sent: nil
    }

    # the VmServer ends normally when QEMU does, which a link does not pass on
    Process.monitor(server)

    if board.io == :raspi,
      do: Process.send_after(self(), :poll, 1_000),
      else: send(self(), :attach)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call({:set_input, gpio, level}, _from, state) do
    state = %{state | inputs: Map.put(state.inputs, gpio, level)}
    {:reply, :ok, changed(state)}
  end

  def handle_call(:pause, _from, %{held?: true} = state), do: {:reply, {:ok, %{}}, state}

  def handle_call(:pause, _from, %{conn: nil} = state),
    do: {:reply, {:error, "gdbstub não conectado"}, state}

  def handle_call(:pause, from, state) do
    # the stop reply arrives as a message: answered from there
    Gdb.interrupt(state.conn)
    {:noreply, %{state | pause_from: from}}
  end

  def handle_call(:resume, _from, %{held?: true} = state),
    do: {:reply, {:ok, %{}}, %{state | held?: false} |> run() |> schedule_tick()}

  def handle_call(:resume, _from, state), do: {:reply, {:ok, %{}}, state}

  @impl true
  def handle_info(:attach, state) do
    case Gdb.connect(state.ports.gdb) do
      {:ok, conn} ->
        with {:ok, conn, b} <- state.backend.attach(conn, state.b),
             {:ok, conn} <- insert(conn, state.backend.watchpoints(b)) do
          state = %{state | conn: conn, b: b, status: :running}
          {:noreply, state |> run() |> schedule_tick() |> changed()}
        else
          error -> fail(state, "não foi possível pôr os watchpoints: #{inspect(error)}")
        end

      {:error, reason} ->
        attempts = state.attempts + 1

        if attempts < @attempts do
          Process.send_after(self(), :attach, 250)
          {:noreply, %{state | attempts: attempts}}
        else
          fail(state, "gdbstub indisponível (#{inspect(reason)})")
        end
    end
  end

  # the backend's turn: stop the CPUs (the stop reply comes as a message)
  def handle_info(:tick, state) do
    state = %{state | tick: nil}

    if state.held? or state.pause_from != nil or state.tick_pending do
      {:noreply, schedule_tick(state)}
    else
      Gdb.interrupt(state.conn)
      {:noreply, %{state | tick_pending: true}}
    end
  end

  def handle_info({:tcp, socket, data}, %{conn: %{socket: socket} = conn} = state) do
    stop_packets(%{state | conn: %{conn | buf: conn.buf <> data}})
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, pid, _}, %{server: pid} = state),
    do: {:stop, :normal, state}

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll)

    case VmServer.qmp(state.id, "human-monitor-command", %{
           "command-line" => Raspi.command(state.board)
         }) do
      {:ok, text} when is_binary(text) ->
        b = Raspi.parse(state.b, text)
        state = %{state | b: b, status: :polling}
        {:noreply, changed(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    snap = snapshot_of(state)

    if snap != state.sent,
      do:
        Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), {:vm_gpio, state.id, snap})

    {:noreply, %{state | flush: nil, sent: snap}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------- gdbstub

  defp stop_packets(state) do
    case Gdb.take_packet(state.conn) do
      {:more, conn} ->
        :inet.setopts(conn.socket, active: :once)
        {:noreply, %{state | conn: conn}}

      {:ok, packet, conn} ->
        stopped(%{state | conn: conn}, packet)
    end
  end

  defp stopped(state, "W" <> _), do: {:stop, :normal, state}
  defp stopped(state, "X" <> _), do: {:stop, :normal, state}

  defp stopped(state, packet) do
    info = Gdb.stop_info(packet)
    tid = Map.get(info, "thread", state.tid)
    state = %{state | tid: tid}

    # ours: a watchpoint, or a breakpoint (SIGTRAP); a pause is SIGINT
    ours? = Gdb.watch?(info) or info.signal == 5

    state =
      if ours? do
        case hit(state) do
          {:ok, state} -> state
          {:error, reason} -> %{state | error: "IO: #{inspect(reason)}"}
        end
      else
        state
      end

    # a hit may come before the interrupt asked for the tick: the CPU is
    # stopped either way, so the tick is done now
    {state, ticked?} =
      if state.tick_pending do
        {do_tick(state), true}
      else
        {state, false}
      end

    cond do
      state.pause_from ->
        GenServer.reply(state.pause_from, {:ok, %{}})
        {:noreply, changed(%{state | pause_from: nil, held?: true})}

      ours? or ticked? ->
        {:noreply, state |> run() |> changed()}

      true ->
        # stopped by someone else (QEMU's monitor): wait for resume/1
        {:noreply, changed(%{state | held?: true})}
    end
  end

  defp hit(state) do
    with {:ok, conn} <- select_thread(state) do
      state = %{state | hg: state.tid}

      ctx = %{
        conn: conn,
        inputs: state.inputs,
        step: fn conn, points -> step(conn, state.tid, points) end
      }

      case state.backend.hit(ctx, state.b) do
        {:ok, conn, b} -> {:ok, %{state | conn: conn, b: b, error: nil}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_tick(state) do
    state = schedule_tick(%{state | tick_pending: false})

    with {:ok, conn} <- select_thread(state),
         {:ok, conn, b} <- state.backend.tick(%{conn: conn, inputs: state.inputs}, state.b) do
      %{state | conn: conn, b: b, hg: state.tid}
    else
      error -> %{state | error: "IO: #{inspect(error)}"}
    end
  end

  defp schedule_tick(%{tick: nil} = state) do
    every =
      if function_exported?(state.backend, :tick_every, 1), do: state.backend.tick_every(state.b)

    if every, do: %{state | tick: Process.send_after(self(), :tick, every)}, else: state
  end

  defp schedule_tick(state), do: state

  # registers are read from the thread `Hg` names: told only when it changes
  defp select_thread(%{hg: tid, tid: tid} = state), do: {:ok, state.conn}

  defp select_thread(state) do
    case Gdb.command(state.conn, "Hg" <> state.tid) do
      {:ok, "OK", conn} -> {:ok, conn}
      {:ok, other, _} -> {:error, other}
      error -> error
    end
  end

  # Over the instruction that stopped: the points that stop it out (or it
  # stops again), one step of the stopped CPU, the points back.
  defp step(conn, tid, watchpoints) do
    with {:ok, conn} <- remove(conn, watchpoints),
         {:ok, _stop, conn} <- Gdb.command(conn, "vCont;s:" <> tid),
         {:ok, conn} <- insert(conn, watchpoints) do
      {:ok, conn}
    end
  end

  defp insert(conn, watchpoints), do: z(conn, "Z", watchpoints)
  defp remove(conn, watchpoints), do: z(conn, "z", watchpoints)

  defp z(conn, op, watchpoints) do
    Enum.reduce_while(watchpoints, {:ok, conn}, fn {type, addr, len}, {:ok, conn} ->
      case Gdb.command(
             conn,
             "#{op}#{type},#{Integer.to_string(addr, 16)},#{Integer.to_string(len, 16)}"
           ) do
        {:ok, "OK", conn} -> {:cont, {:ok, conn}}
        {:ok, other, _} -> {:halt, {:error, other}}
        error -> {:halt, error}
      end
    end)
  end

  defp run(state) do
    Gdb.send_packet(state.conn, "c")
    :inet.setopts(state.conn.socket, active: :once)
    state
  end

  defp fail(state, msg) do
    Logger.warning("GPIO de #{state.id}: #{msg}")
    send(state.server, {:gdb_failed, msg})
    {:noreply, changed(%{state | status: :error, error: msg})}
  end

  # ------------------------------------------------------------ snapshot

  defp snapshot_of(state) do
    %{
      pins: state.backend.pins(state.b, state.board, state.inputs),
      driven: state.inputs,
      status: if(state.held?, do: :paused, else: state.status),
      error: state.error,
      inputs?: state.board.io != :raspi
    }
  end

  defp changed(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @flush)}

  defp changed(state), do: state
end
