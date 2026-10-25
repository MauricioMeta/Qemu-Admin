defmodule QemuAdmin.Gpio.Avr do
  @moduledoc """
  An Arduino's ports, followed through the gdbstub (`QemuAdmin.Gpio`).
  QEMU maps the ATmega's GPIO as an unimplemented device — writes dropped,
  reads 0 — and reaches the I/O registers by a path watchpoints do not see.
  So on attach the program is read from the flash and a breakpoint goes on
  every instruction that may touch a port register (`PINx`, `DDRx`,
  `PORTx`, three bytes per port in data space): the ones naming one
  (`IN`, `OUT`, `SBI`, `CBI`, `SBIS`, `SBIC`, `LDS`, `STS`) and the plain
  loads and stores through X and Z, which is how the Arduino core's
  `digitalWrite` and `digitalRead` reach them (`breakpoint?/2`). On a stop
  the instruction and the registers say what the access is:

    * `OUT`, `STS`, `ST`/`STD` (through X, Y, Z) — a write of a register's
      value; `SBI`/`CBI` set or clear a bit. Kept here, the instruction
      stepped over. Writing a 1 to `PINx` toggles `PORTx`, as on the chip;
    * `IN`, `LDS`, `LD`/`LDD` — stepped over, then the target register gets
      the value: `DDRx`, `PORTx`, and for `PINx` the outputs where `DDRx`
      says so and elsewhere the inputs (high with the pull-up on, unless
      set);
    * `SBIS`/`SBIC` — not run at all: the PC jumps where the bit says;
    * anything else (a pointer that was not at a port) — stepped over.

  QEMU has no 8-bit timers either, and the Arduino core counts `millis()`,
  `micros()` and `delay()` in Timer0's overflow interrupt. So, when the
  program has that handler, `tick/2` (every 20 ms) stands in for the
  timer: with interrupts enabled, it makes the CPU enter the handler once
  per 1.024 ms gone by (the overflow period at 16 MHz with the core's
  prescaler of 64) — the return addresses pushed so that each `RETI` runs
  it again and the last one goes back to where the program was.

  gdbstub registers: r0–r31 are 0–31, SREG 32, SP 33, PC 34 (a byte address
  in program memory, which is also where memory reads below 0x800000 go).
  """

  import Bitwise

  alias QemuAdmin.{Board, Gdb}

  @pc 34

  # where each port's PINx sits in data space (DDRx and PORTx follow)
  @pin_addr %{
    "A" => 0x20,
    "B" => 0x23,
    "C" => 0x26,
    "D" => 0x29,
    "E" => 0x2C,
    "F" => 0x2F,
    "G" => 0x32,
    "H" => 0x100,
    "J" => 0x103,
    "K" => 0x106,
    "L" => 0x109
  }

  def init(board) do
    ports =
      board
      |> Board.gpios()
      |> Enum.map(&Enum.at(Board.avr_ports(), div(&1, 8)))
      |> Enum.uniq()
      |> Enum.sort_by(&@pin_addr[&1])

    flash =
      case board.machine do
        "arduino-mega-2560-v3" -> 262_144
        "arduino-mega" -> 131_072
        _ -> 32_768
      end

    %{
      ports: ports,
      regs: Map.new(ports, &{&1, %{ddr: 0, port: 0}}),
      flash: flash,
      program: "",
      points: [],
      # TIMER0_OVF's vector (a byte address), its return addresses' width
      timer0: if(flash > 32_768, do: 23 * 4, else: 16 * 4),
      pc_bytes: if(flash > 131_072, do: 3, else: 2),
      vector: nil,
      t0: nil
    }
  end

  @chunk 1024

  @doc "Reads the program and finds where to break (`breakpoints/2`)."
  def attach(conn, b) do
    with {:ok, program, conn} <- read_program(conn, 0, b.flash, []) do
      points = Enum.map(breakpoints(program, b), &{0, &1, 2})
      vector = if handler?(program, b.timer0), do: b.timer0
      {:ok, conn, %{b | program: program, points: points, vector: vector, t0: now()}}
    end
  end

  # up to the end of the flash, or two blank chunks in a row
  defp read_program(conn, addr, size, acc) when addr >= size,
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), conn}

  defp read_program(conn, addr, size, acc) do
    with {:ok, data, conn} <- Gdb.read_mem(conn, addr, @chunk) do
      blank? = data == :binary.copy(<<0xFF>>, byte_size(data))

      case {blank?, acc} do
        {true, [prev | _]} when prev == data -> read_program(conn, size, size, acc)
        _ -> read_program(conn, addr + @chunk, size, [data | acc])
      end
    end
  end

  def watchpoints(%{points: points}), do: points

  # The vector holds a JMP to a handler of its own (the unused vectors all
  # jump to the same __bad_interrupt, as INT0's does in a sketch without it).
  defp handler?(program, vector) do
    case {jmp_target(program, vector), jmp_target(program, 4)} do
      {nil, _} -> false
      {target, other} -> target != other
    end
  end

  defp jmp_target(program, at) when byte_size(program) >= at + 4 do
    <<_::binary-size(^at), w1::little-16, w2::little-16, _::binary>> = program

    if (w1 &&& 0xFE0E) == 0x940C,
      do: ((w1 >>> 3 &&& 0x3E) ||| (w1 &&& 1)) <<< 16 ||| w2,
      else: nil
  end

  defp jmp_target(_program, _at), do: nil

  @tick 20
  @period 1.024

  def tick_every(%{vector: nil}), do: nil
  def tick_every(_b), do: @tick

  defp now, do: System.monotonic_time(:microsecond) / 1000

  @doc "Timer0's overflows since the last tick, as entries into its handler (see the moduledoc)."
  def tick(%{conn: conn}, %{vector: vector} = b) when is_integer(vector) do
    n = min(trunc((now() - b.t0) / @period), 32)

    with true <- n > 0 || :none,
         {:ok, regs, conn} <- Gdb.read_regs(conn),
         <<_r::binary-size(32), sreg, sp::little-16, pc::little-32, _::binary>> <- regs,
         true <- (sreg &&& 0x80) != 0 || {:masked, conn} do
      frame = fn word -> <<word::big-size(b.pc_bytes * 8)>> end

      frames =
        IO.iodata_to_binary([List.duplicate(frame.(div(vector, 2)), n - 1), frame.(div(pc, 2))])

      new_sp = sp - byte_size(frames)
      hex = Base.encode16(frames, case: :lower)

      with {:ok, "OK", conn} <-
             Gdb.command(
               conn,
               "M#{Integer.to_string(0x800000 + new_sp + 1, 16)},#{Integer.to_string(byte_size(frames), 16)}:#{hex}"
             ),
           {:ok, conn} <- Gdb.write_reg(conn, 33, new_sp, 2),
           {:ok, conn} <- Gdb.write_reg(conn, 32, sreg &&& 0x7F, 1),
           {:ok, conn} <- Gdb.write_reg(conn, @pc, vector, 4) do
        {:ok, conn, %{b | t0: b.t0 + n * @period}}
      end
    else
      # interrupts off (a cli section): the overflows wait for the next tick
      :none -> {:ok, conn, b}
      {:masked, conn} -> {:ok, conn, b}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  def tick(%{conn: conn}, b), do: {:ok, conn, b}

  @doc "The byte addresses of the instructions in `program` that may reach a port."
  def breakpoints(program, b) do
    words = for <<w::little-16 <- program>>, do: w
    scan(words, 0, b, [])
  end

  defp scan([], _pc, _b, acc), do: Enum.reverse(acc)

  defp scan([w1], pc, b, acc),
    do: scan([], pc + 2, b, if(breakpoint?({w1, 0xFFFF}, b), do: [pc | acc], else: acc))

  defp scan([w1, w2 | rest], pc, b, acc) do
    acc = if breakpoint?({w1, w2}, b), do: [pc | acc], else: acc

    if insn_size(w1) == 4,
      do: scan(rest, pc + 4, b, acc),
      else: scan([w2 | rest], pc + 2, b, acc)
  end

  @doc "Whether the instruction (`{w1, w2}`) names a port register or loads/stores through plain X, Y or Z."
  def breakpoint?({w1, w2}, b) do
    plain_pointer? = (w1 &&& 0xFC0F) in [0x900C, 0x920C, 0x8000, 0x8200, 0x8008, 0x8208]

    case decode(w1, w2, List.to_tuple(List.duplicate(0, 32))) do
      {:load, _, addr} when (w1 &&& 0xF000) == 0xB000 or (w1 &&& 0xFC0F) == 0x9000 ->
        port?(b, addr)

      {:store, _, addr} when (w1 &&& 0xF000) == 0xB000 or (w1 &&& 0xFC0F) == 0x9000 ->
        port?(b, addr)

      {:bit, _, addr, _} ->
        port?(b, addr)

      {:skip_if, _, addr, _} ->
        port?(b, addr)

      _ ->
        plain_pointer?
    end
  end

  defp port?(b, addr), do: locate(b, addr) != nil

  def hit(%{conn: conn} = ctx, b) do
    with {:ok, regs, conn} <- Gdb.read_regs(conn),
         <<r::binary-size(32), _sreg, _sp::16, pc::little-32, _::binary>> <- regs,
         {:ok, insn, conn} <- instruction(conn, b, pc) do
      r = :binary.bin_to_list(r) |> List.to_tuple()
      <<w1::little-16, w2::little-16>> = insn
      ctx = %{ctx | conn: conn}
      here = [{0, pc, 2}]

      case decode(w1, w2, r) do
        {:store, rr, addr} ->
          with {:ok, conn} <- ctx.step.(conn, here), do: {:ok, conn, store(b, addr, elem(r, rr))}

        {:bit, set?, addr, bit} ->
          with {:ok, conn} <- ctx.step.(conn, here), do: {:ok, conn, set_bit(b, addr, bit, set?)}

        {:load, d, addr} ->
          with {:ok, conn} <- ctx.step.(conn, here) do
            case load(b, addr, ctx.inputs) do
              nil -> {:ok, conn, b}
              value -> with {:ok, conn} <- Gdb.write_reg(conn, d, value, 1), do: {:ok, conn, b}
            end
          end

        {:skip_if, value, addr, bit} ->
          level = (load(b, addr, ctx.inputs) || 0) >>> bit &&& 1
          next = if level == value, do: pc + 2 + insn_size(w2), else: pc + 2
          with {:ok, conn} <- Gdb.write_reg(conn, @pc, next, 4), do: {:ok, conn, b}

        :unknown ->
          with {:ok, conn} <- ctx.step.(conn, here), do: {:ok, conn, b}
      end
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  # from the program read on attach (the flash does not change while it runs)
  defp instruction(conn, %{program: program}, pc) when pc + 4 <= byte_size(program),
    do: {:ok, binary_part(program, pc, 4), conn}

  defp instruction(conn, _b, pc), do: Gdb.read_mem(conn, pc, 4)

  @doc """
  The data access of the instruction `w1` (`w2` the word after it), with
  `r` the registers as a tuple: `{:store, rr, addr}`, `{:load, rd, addr}`,
  `{:bit, set?, addr, bit}`, `{:skip_if, level, addr, bit}` or `:unknown`.
  Addresses are in data space (I/O address + 0x20).
  """
  def decode(w1, w2, r) do
    d = w1 >>> 4 &&& 0x1F
    io = (w1 >>> 5 &&& 0x30) ||| (w1 &&& 0xF)
    bio = (w1 >>> 3 &&& 0x1F) + 0x20
    bit = w1 &&& 7
    store? = (w1 &&& 0x0200) != 0

    cond do
      (w1 &&& 0xF800) == 0xB000 -> {:load, d, io + 0x20}
      (w1 &&& 0xF800) == 0xB800 -> {:store, d, io + 0x20}
      (w1 &&& 0xFF00) == 0x9A00 -> {:bit, true, bio, bit}
      (w1 &&& 0xFF00) == 0x9800 -> {:bit, false, bio, bit}
      (w1 &&& 0xFF00) == 0x9B00 -> {:skip_if, 1, bio, bit}
      (w1 &&& 0xFF00) == 0x9900 -> {:skip_if, 0, bio, bit}
      (w1 &&& 0xFC0F) == 0x9000 -> access(store?, d, w2)
      (w1 &&& 0xFC00) == 0x9000 -> pointer(w1 &&& 0xF, store?, d, r)
      (w1 &&& 0xD000) == 0x8000 -> displaced(w1, store?, d, r)
      true -> :unknown
    end
  end

  defp access(true, d, addr), do: {:store, d, addr}
  defp access(false, d, addr), do: {:load, d, addr}

  defp pointer(mode, store?, d, r) do
    x = word(r, 26)
    y = word(r, 28)
    z = word(r, 30)

    case mode do
      0xC -> access(store?, d, x)
      0xD -> access(store?, d, x)
      0xE -> access(store?, d, x - 1)
      0x9 -> access(store?, d, y)
      0xA -> access(store?, d, y - 1)
      0x1 -> access(store?, d, z)
      0x2 -> access(store?, d, z - 1)
      _ -> :unknown
    end
  end

  # LDD/STD: 10q0 qqsd dddd yqqq — Y (y = 1) or Z plus q
  defp displaced(w1, store?, d, r) do
    q = (w1 >>> 8 &&& 0x20) ||| (w1 >>> 7 &&& 0x18) ||| (w1 &&& 7)
    ptr = if (w1 &&& 0x8) != 0, do: word(r, 28), else: word(r, 30)
    access(store?, d, ptr + q)
  end

  defp word(r, lo), do: elem(r, lo) ||| elem(r, lo + 1) <<< 8

  # JMP, CALL, LDS and STS take two words
  defp insn_size(w) do
    if (w &&& 0xFE0C) == 0x940C or (w &&& 0xFC0F) == 0x9000, do: 4, else: 2
  end

  defp locate(b, addr) do
    Enum.find_value(b.ports, fn port ->
      offset = addr - @pin_addr[port]
      if offset in 0..2, do: {port, offset}
    end)
  end

  @doc "A write of `value` to data address `addr`."
  def store(b, addr, value) do
    case locate(b, addr) do
      {port, 0} -> update(b, port, &%{&1 | port: bxor(&1.port, value)})
      {port, 1} -> update(b, port, &%{&1 | ddr: value})
      {port, 2} -> update(b, port, &%{&1 | port: value})
      nil -> b
    end
  end

  defp set_bit(b, addr, bit, set?) do
    case locate(b, addr) do
      # SBI on PINx toggles the PORTx bit
      {port, 0} -> if set?, do: update(b, port, &%{&1 | port: bxor(&1.port, 1 <<< bit)}), else: b
      {port, 1} -> update(b, port, &%{&1 | ddr: put_bit(&1.ddr, bit, set?)})
      {port, 2} -> update(b, port, &%{&1 | port: put_bit(&1.port, bit, set?)})
      nil -> b
    end
  end

  @doc "What a read of data address `addr` gives (nil: not a port register)."
  def load(b, addr, inputs) do
    case locate(b, addr) do
      {port, 0} -> pin(b, port, inputs)
      {port, 1} -> b.regs[port].ddr
      {port, 2} -> b.regs[port].port
      nil -> nil
    end
  end

  defp pin(b, port, inputs) do
    %{ddr: ddr, port: out} = b.regs[port]

    Enum.reduce(0..7, 0, fn bit, acc ->
      level =
        if (ddr >>> bit &&& 1) == 1,
          do: out >>> bit &&& 1,
          else: Map.get(inputs, Board.avr_gpio(port, bit), out >>> bit &&& 1)

      acc ||| level <<< bit
    end)
  end

  defp put_bit(v, bit, true), do: v ||| 1 <<< bit
  defp put_bit(v, bit, false), do: v &&& bnot(1 <<< bit) &&& 0xFF

  defp update(b, port, fun), do: %{b | regs: Map.update!(b.regs, port, fun)}

  def pins(b, board, inputs) do
    Map.new(Board.gpios(board), fn g ->
      port = Enum.at(Board.avr_ports(), div(g, 8))
      bit = rem(g, 8)
      %{ddr: ddr, port: out} = b.regs[port]
      level = pin(b, port, inputs) >>> bit &&& 1

      {g,
       %{
         dir: if((ddr >>> bit &&& 1) == 1, do: :out, else: :in),
         level: level,
         pullup: (out >>> bit &&& 1) == 1
       }}
    end)
  end
end
