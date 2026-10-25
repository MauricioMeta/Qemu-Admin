defmodule QemuAdmin.Gpio.Raspi do
  @moduledoc """
  A Raspberry Pi's GPIO, read over QMP (`QemuAdmin.Gpio`): QEMU models the
  BCM2835's GPIO block, so `xp` of its first registers gives GPFSEL0–5
  (0x00–0x14, three bits per pin: 0 input, 1 output, else an alternate
  function) and GPLEV0–1 (0x34, 0x38, the levels).
  """

  import Bitwise

  def init(board), do: %{base: board.gpio_base, fsel: List.duplicate(0, 6), lev: 0}

  def command(board), do: "xp /15wx 0x#{Integer.to_string(board.gpio_base, 16)}"

  @doc "The registers out of `xp`'s text (`addr: 0x… 0x… …` lines)."
  def parse(b, text) do
    words =
      text
      |> String.split(~r/\R/, trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [_addr, rest] -> Regex.scan(~r/0x([0-9a-fA-F]+)/, rest, capture: :all_but_first)
          _ -> []
        end
      end)
      |> Enum.map(fn [hex] -> String.to_integer(hex, 16) end)

    if length(words) >= 15,
      do: %{b | fsel: Enum.take(words, 6), lev: Enum.at(words, 13) ||| Enum.at(words, 14) <<< 32},
      else: b
  end

  def pins(b, board, _inputs) do
    Map.new(QemuAdmin.Board.gpios(board), fn g ->
      fsel = Enum.at(b.fsel, div(g, 10)) >>> (rem(g, 10) * 3) &&& 7

      dir =
        case fsel do
          0 -> :in
          1 -> :out
          _ -> :alt
        end

      {g, %{dir: dir, level: b.lev >>> g &&& 1}}
    end)
  end
end
