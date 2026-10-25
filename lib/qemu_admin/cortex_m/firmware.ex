defmodule QemuAdmin.CortexM.Firmware do
  @moduledoc """
  A Cortex-M board's program (an STM32, as the Netduino Plus 2): an `.elf`
  (what the toolchains, Zephyr, RTEMS and FreeRTOS builds produce), a raw
  `.bin` (loaded at the flash, by QEMU's `-kernel`) or an Intel `.hex`, which
  becomes the `.bin` from its lowest address (the flash starts at
  `0x08000000`). The file lives in the VM's folder as `firmware.elf` or
  `firmware.bin` (`QemuAdmin.Vm.Args.cortexm_firmware/1`).
  """

  alias QemuAdmin.Avr.Firmware, as: Hex

  @names ~w(firmware.elf firmware.bin)

  def extensions, do: ~w(.elf .bin .hex)

  @doc "Puts the program at `src` in `dir` as the board's flash."
  def install(dir, src) do
    with {:ok, data} <- File.read(src),
         {:ok, name, image} <- convert(Path.extname(src) |> String.downcase(), data) do
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

  defp convert(".elf", <<0x7F, "ELF", _::binary>> = data), do: {:ok, "firmware.elf", data}
  defp convert(".elf", _), do: {:error, "não é um arquivo ELF"}
  defp convert(".bin", data) when byte_size(data) > 0, do: {:ok, "firmware.bin", data}
  defp convert(".bin", _), do: {:error, "arquivo vazio"}

  defp convert(".hex", text) do
    with {:ok, image} <- Hex.parse_hex(text, :rebase) do
      {:ok, "firmware.bin", image}
    end
  end

  defp convert(ext, _), do: {:error, "formato #{ext} não suportado (use .elf, .bin ou .hex)"}
end
