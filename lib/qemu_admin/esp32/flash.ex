defmodule QemuAdmin.Esp32.Flash do
  @moduledoc """
  An ESP32's SPI flash, as the file QEMU boots (`-drive if=mtd`): a raw
  image of exactly 2, 4, 8 or 16 MiB, erased bytes being `0xFF` — what
  `esptool.py write_flash` would leave on a real chip, done to a file.

    * `create/2` and `erase/1` — a blank chip;
    * `write/3` — a binary (a file's contents) at an offset, the region it
      covers first erased, as the chip would be;
    * `partitions/1` — the partition table ESP-IDF writes at `0x8000`, so
      an AtomVM app (`.avm`) goes where the firmware expects it.
  """

  import Bitwise

  @sizes [2, 4, 8, 16]
  @table_offset 0x8000
  @table_size 0xC00

  @doc "The flash sizes QEMU's ESP32 accepts, in MiB."
  def sizes, do: @sizes

  @doc """
  Where the second-stage bootloader sits on `machine` — the offset of a
  firmware image that starts with it (AtomVM's `.img`, `esptool merge_bin`
  output). The ESP32 boots it from `0x1000`, the ESP32-S3 from `0x0`.
  """
  def bootloader_offset("esp32"), do: 0x1000
  def bootloader_offset(_), do: 0x0

  @doc "A blank flash of `mib` MiB at `path`."
  def create(path, mib) when mib in @sizes do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, :binary.copy(<<0xFF>>, mib * 1_048_576))
  end

  def create(_path, mib),
    do:
      {:error, "tamanho de flash inválido: #{inspect(mib)} MiB (use #{Enum.join(@sizes, ", ")})"}

  @doc "The flash size in bytes, or an error when `path` is no flash image."
  def size(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}}
      when size in [2_097_152, 4_194_304, 8_388_608, 16_777_216] ->
        {:ok, size}

      {:ok, %{size: size}} ->
        {:error, "#{Path.basename(path)} tem #{size} bytes — uma flash tem 2, 4, 8 ou 16 MiB"}

      {:error, reason} ->
        {:error, "#{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Every byte back to `0xFF`."
  def erase(path) do
    with {:ok, size} <- size(path) do
      File.write(path, :binary.copy(<<0xFF>>, size))
    end
  end

  @doc """
  Writes `data` at `offset`. With `erase: {from, len}` that region is
  erased first (a partition, so an old app's tail does not linger).
  """
  def write(path, offset, data, opts \\ []) when is_binary(data) and is_integer(offset) do
    with {:ok, size} <- size(path),
         :ok <- fits(offset, byte_size(data), size) do
      {:ok, io} = :file.open(path, [:read, :write, :binary, :raw])

      try do
        case Keyword.get(opts, :erase) do
          {from, len} ->
            :ok = :file.pwrite(io, from, :binary.copy(<<0xFF>>, min(len, size - from)))

          nil ->
            :ok
        end

        :file.pwrite(io, offset, data)
      after
        :file.close(io)
      end
    end
  end

  defp fits(offset, _len, _size) when offset < 0, do: {:error, "endereço negativo"}

  defp fits(offset, len, size) when offset + len > size,
    do:
      {:error,
       "#{len} bytes em 0x#{hex(offset)} passam do fim da flash (#{div(size, 1_048_576)} MiB)"}

  defp fits(_offset, _len, _size), do: :ok

  @doc """
  The partition table: `[%{name:, type:, subtype:, offset:, size:, used:}]`,
  `type` `:app` or `:data`, `used` whether anything but `0xFF` is in it.
  `[]` when the flash has no table (blank, or not ESP-IDF).
  """
  def partitions(path) do
    with {:ok, io} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(io, @table_offset, @table_size) do
          {:ok, table} -> table |> entries([]) |> Enum.map(&Map.put(&1, :used, used?(io, &1)))
          _ -> []
        end
      after
        :file.close(io)
      end
    else
      _ -> []
    end
  end

  # 32-byte entries, magic 0xAA50, until the first that is not one (the MD5
  # entry starts 0xEBEB, erased flash 0xFFFF).
  defp entries(
         <<0xAA, 0x50, type, subtype, offset::little-32, size::little-32, name::binary-16,
           _flags::binary-4, rest::binary>>,
         acc
       ) do
    entry = %{
      name: name |> :binary.split(<<0>>) |> hd(),
      type: if(type == 0, do: :app, else: :data),
      subtype: subtype,
      offset: offset,
      size: size
    }

    entries(rest, [entry | acc])
  end

  defp entries(_rest, acc), do: Enum.reverse(acc)

  # The first 4 KiB tell: an image, an .avm or a filesystem all start there.
  defp used?(io, %{offset: offset, size: size}) do
    case :file.pread(io, offset, min(size, 4096)) do
      {:ok, bytes} -> bytes != :binary.copy(<<0xFF>>, byte_size(bytes))
      _ -> false
    end
  end

  @doc "The partition called `name`, or nil."
  def partition(path, name), do: Enum.find(partitions(path), &(&1.name == name))

  @doc """
  The partitions an AtomVM app can go to: data partitions named `*.avm`,
  except `boot.avm` (AtomVM's own libraries).
  """
  def avm_partitions(path) do
    Enum.filter(
      partitions(path),
      &(&1.type == :data and String.ends_with?(&1.name, ".avm") and &1.name != "boot.avm")
    )
  end

  @doc "`0x250000` → `\"250000\"`."
  def hex(n), do: Integer.to_string(n, 16)

  @doc "An offset as esptool takes it, always hexadecimal: \"0x1000\" or \"1000\" → 4096."
  def parse_offset(text) do
    digits =
      text |> to_string() |> String.trim() |> String.downcase() |> String.replace_prefix("0x", "")

    case Integer.parse(digits, 16) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "endereço inválido: #{text} (hexadecimal, ex. 0x250000)"}
    end
  end

  @doc "Whether `offset` is on a 4 KiB sector boundary (esptool's own rule)."
  def aligned?(offset), do: (offset &&& 0xFFF) == 0
end
