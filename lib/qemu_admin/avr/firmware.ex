defmodule QemuAdmin.Avr.Firmware do
  @moduledoc """
  An Arduino's program, the board's flash: what the Arduino IDE or
  `arduino-cli compile --output-dir` produces — `.hex` (Intel HEX), `.elf`
  or a raw `.bin`. QEMU loads an ELF or a raw image (`-bios`), so a `.hex`
  becomes `firmware.bin` and an `.elf` is kept as `firmware.elf`, in the
  VM's folder (`QemuAdmin.Vm.Args.avr_firmware/1`).
  """

  import Bitwise

  @names ~w(firmware.elf firmware.bin)

  def extensions, do: ~w(.hex .elf .bin)

  @doc "The flash size of an Arduino board (QEMU machine)."
  def flash_size("arduino-mega-2560-v3"), do: 262_144
  def flash_size("arduino-mega"), do: 131_072
  def flash_size(_uno), do: 32_768

  @doc "Puts the program at `src` in `dir` as the board's flash."
  def install(dir, src, machine) do
    with {:ok, data} <- File.read(src),
         {:ok, name, image} <- convert(Path.extname(src) |> String.downcase(), data),
         :ok <- fits(name, image, machine) do
      File.mkdir_p!(dir)
      Enum.each(@names, &File.rm(Path.join(dir, &1)))
      File.write!(Path.join(dir, name), image)
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{src}: #{:file.format_error(reason)}"}
      error -> error
    end
  end

  @doc "Takes the program off the board."
  def erase(dir), do: Enum.each(@names, &File.rm(Path.join(dir, &1)))

  defp convert(".hex", text),
    do: with({:ok, bin} <- parse_hex(text), do: {:ok, "firmware.bin", bin})

  defp convert(".elf", <<0x7F, "ELF", _::binary>> = data), do: {:ok, "firmware.elf", data}
  defp convert(".elf", _), do: {:error, "não é um arquivo ELF"}
  defp convert(".bin", data), do: {:ok, "firmware.bin", data}
  defp convert(ext, _), do: {:error, "formato #{ext} não suportado (use .hex, .elf ou .bin)"}

  defp fits("firmware.bin", image, machine) do
    max = flash_size(machine)

    if byte_size(image) <= max,
      do: :ok,
      else: {:error, "o programa (#{byte_size(image)} bytes) não cabe na flash (#{max})"}
  end

  defp fits(_elf, _image, _machine), do: :ok

  @doc """
  An Intel HEX file as the flash image from address 0, gaps filled with
  0xFF (erased flash). Records 00 (data), 01 (end), 02 and 04 (segment and
  linear base) are understood; checksums are checked. With `:rebase` the
  image starts at the lowest address instead of 0.
  """
  def parse_hex(text, mode \\ :from_zero) do
    text
    |> String.split(~r/\R/, trim: true)
    |> Enum.reduce_while({:ok, 0, []}, fn line, {:ok, base, chunks} ->
      case record(String.trim(line)) do
        {:data, addr, bytes} -> {:cont, {:ok, base, [{base + addr, bytes} | chunks]}}
        {:base, new} -> {:cont, {:ok, new, chunks}}
        :eof -> {:halt, {:ok, base, chunks}}
        :skip -> {:cont, {:ok, base, chunks}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
    |> case do
      {:ok, _base, chunks} -> {:ok, chunks |> Enum.reverse() |> rebase(mode) |> assemble()}
      error -> error
    end
  end

  defp record(":" <> hex) do
    with {:ok, <<len, addr::16, type, rest::binary>> = bin} <- Base.decode16(hex, case: :mixed),
         true <- byte_size(rest) == len + 1 || {:error, "registro HEX com tamanho errado"},
         true <-
           (bin |> :binary.bin_to_list() |> Enum.sum() &&& 0xFF) == 0 ||
             {:error, "checksum do HEX não confere"} do
      data = binary_part(rest, 0, len)

      case type do
        0 -> {:data, addr, data}
        1 -> :eof
        2 -> {:base, :binary.decode_unsigned(data) <<< 4}
        4 -> {:base, :binary.decode_unsigned(data) <<< 16}
        _ -> :skip
      end
    else
      :error -> {:error, "não é um arquivo Intel HEX"}
      error -> error
    end
  end

  defp record(""), do: :skip
  defp record(_), do: {:error, "não é um arquivo Intel HEX"}

  # `:rebase` starts the image at the lowest address, as a Cortex-M's flash
  # (0x08000000 on the STM32) is loaded at its start
  defp rebase(chunks, :rebase) when chunks != [] do
    lowest = chunks |> Enum.map(&elem(&1, 0)) |> Enum.min()
    Enum.map(chunks, fn {addr, data} -> {addr - lowest, data} end)
  end

  defp rebase(chunks, _mode), do: chunks

  defp assemble([]), do: ""

  defp assemble(chunks) do
    size = chunks |> Enum.map(fn {a, d} -> a + byte_size(d) end) |> Enum.max()
    image = :binary.copy(<<0xFF>>, size)

    Enum.reduce(chunks, image, fn {addr, data}, img ->
      len = byte_size(data)
      <<pre::binary-size(^addr), _::binary-size(^len), post::binary>> = img
      <<pre::binary, data::binary, post::binary>>
    end)
  end
end
