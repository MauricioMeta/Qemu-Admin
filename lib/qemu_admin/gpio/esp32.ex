defmodule QemuAdmin.Gpio.Esp32 do
  @moduledoc """
  The ESP32's (and ESP32-S3's) GPIO, followed through the gdbstub
  (`QemuAdmin.Gpio`). Espressif's QEMU maps the GPIO block but keeps none
  of it, so these registers are watched (offsets from the block's base):

      0x04 OUT      0x08 OUT_W1TS     0x0C OUT_W1TC      GPIO 0–31
      0x10 OUT1     0x14 OUT1_W1TS    0x18 OUT1_W1TC     GPIO 32–
      0x20 ENABLE   0x24 ENABLE_W1TS  0x28 ENABLE_W1TC
      0x2C ENABLE1  0x30 ENABLE1_W1TS 0x34 ENABLE1_W1TC
      0x3C IN       0x40 IN1

  On a stop the instruction at the PC — `s32i`/`s32i.n` or `l32i`/`l32i.n`,
  what ESP-IDF's `gpio_ll` compiles to — gives the register (base register
  plus offset) and the value (a store's source); a load is stepped over and
  its target register then gets the value: the outputs and enables kept
  here, and for IN, the outputs where enabled and the inputs elsewhere.
  `STRAP` (0x38) is read as QEMU answers it.

  The registers are the windowed AR file: `a<n>` is physical
  `(WINDOWBASE * 4 + n) mod 64`; in the gdbstub's numbering the PC is 0,
  AR0–AR63 are 1–64 and WINDOWBASE is 0x45.
  """

  import Bitwise

  alias QemuAdmin.Gdb

  @pc 0
  @windowbase 0x45

  def init(board) do
    base = if board.machine == "esp32s3", do: 0x60004000, else: 0x3FF44000
    %{base: base, out: 0, en: 0}
  end

  def attach(conn, b), do: {:ok, conn, b}

  def watchpoints(%{base: base}), do: [{4, base + 0x04, 0x40}]

  def hit(%{conn: conn} = ctx, b) do
    with {:ok, pc, conn} <- Gdb.read_reg(conn, @pc),
         {:ok, wb, conn} <- Gdb.read_reg(conn, @windowbase),
         {:ok, insn, conn} <- Gdb.read_mem(conn, pc, 3) do
      ar = fn conn, n -> Gdb.read_reg(conn, 1 + rem(wb * 4 + n, 64)) end

      case decode(insn) do
        {op, t, s, off} ->
          with {:ok, base, conn} <- ar.(conn, s) do
            reg = base + off - b.base
            access(op, %{ctx | conn: conn}, b, reg, 1 + rem(wb * 4 + t, 64))
          end

        :unknown ->
          with {:ok, conn} <- ctx.step.(conn, watchpoints(b)), do: {:ok, conn, b}
      end
    end
  end

  @doc """
  `{:store | :load, t, s, offset}` for the 32-bit stores and loads (`at`,
  `as`, the byte offset), `:unknown` otherwise.
  """
  def decode(<<b0, b1, b2>>) do
    op0 = b0 &&& 0xF
    t = b0 >>> 4
    s = b1 &&& 0xF
    r = b1 >>> 4

    cond do
      op0 == 2 and r == 6 -> {:store, t, s, b2 * 4}
      op0 == 2 and r == 2 -> {:load, t, s, b2 * 4}
      op0 == 9 -> {:store, t, s, r * 4}
      op0 == 8 -> {:load, t, s, r * 4}
      true -> :unknown
    end
  end

  def decode(_), do: :unknown

  defp access(:store, ctx, b, reg, at) do
    with {:ok, value, conn} <- Gdb.read_reg(ctx.conn, at),
         {:ok, conn} <- ctx.step.(conn, watchpoints(b)) do
      {:ok, conn, write(b, reg, value)}
    end
  end

  defp access(:load, ctx, b, reg, at) do
    with {:ok, conn} <- ctx.step.(ctx.conn, watchpoints(b)) do
      case read(b, reg, ctx.inputs) do
        nil ->
          {:ok, conn, b}

        value ->
          with {:ok, conn} <- Gdb.write_reg(conn, at, value, 4), do: {:ok, conn, b}
      end
    end
  end

  @doc "What a store of `v` to register offset `reg` does to `%{out:, en:}` (64-bit masks)."
  def write(b, reg, v) do
    case reg do
      0x04 -> %{b | out: set_word(b.out, 0, v)}
      0x08 -> %{b | out: b.out ||| v}
      0x0C -> %{b | out: b.out &&& bnot(v)}
      0x10 -> %{b | out: set_word(b.out, 1, v)}
      0x14 -> %{b | out: b.out ||| v <<< 32}
      0x18 -> %{b | out: b.out &&& bnot(v <<< 32)}
      0x20 -> %{b | en: set_word(b.en, 0, v)}
      0x24 -> %{b | en: b.en ||| v}
      0x28 -> %{b | en: b.en &&& bnot(v)}
      0x2C -> %{b | en: set_word(b.en, 1, v)}
      0x30 -> %{b | en: b.en ||| v <<< 32}
      0x34 -> %{b | en: b.en &&& bnot(v <<< 32)}
      _ -> b
    end
  end

  @doc "What a load of register offset `reg` returns (nil: leave QEMU's answer)."
  def read(b, reg, inputs) do
    case reg do
      0x04 -> word(b.out, 0)
      0x10 -> word(b.out, 1)
      0x20 -> word(b.en, 0)
      0x2C -> word(b.en, 1)
      0x3C -> word(in_mask(b, inputs), 0)
      0x40 -> word(in_mask(b, inputs), 1)
      _ -> nil
    end
  end

  defp in_mask(b, inputs) do
    driven =
      Enum.reduce(inputs, 0, fn {g, l}, acc -> if l == 1, do: acc ||| 1 <<< g, else: acc end)

    (b.out &&& b.en) ||| (driven &&& bnot(b.en))
  end

  defp word(mask, i), do: mask >>> (32 * i) &&& 0xFFFFFFFF

  defp set_word(mask, i, v),
    do: (mask &&& bnot(0xFFFFFFFF <<< (32 * i))) ||| (v &&& 0xFFFFFFFF) <<< (32 * i)

  def pins(b, board, inputs) do
    Map.new(QemuAdmin.Board.gpios(board), fn g ->
      if (b.en >>> g &&& 1) == 1,
        do: {g, %{dir: :out, level: b.out >>> g &&& 1}},
        else: {g, %{dir: :in, level: Map.get(inputs, g, 0)}}
    end)
  end
end
