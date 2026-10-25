defmodule QemuAdmin.Raspi.Fat do
  @moduledoc """
  Reads files from the root of the first FAT partition (FAT16 or FAT32) of
  a disk image — the boot partition of a Raspberry Pi SD card, where the
  kernel, the device trees and `cmdline.txt` live — and creates small ones
  there (`create/3`: `userconf.txt`, `ssh`). Only the root folder and 8.3
  names: that is all QEMU's `-kernel`/`-dtb` and Raspberry Pi OS's first
  boot need.
  """

  import Bitwise

  @fat_types [0x01, 0x04, 0x06, 0x0B, 0x0C, 0x0E]

  @doc "Opens the image's first FAT partition (`:write` to create files too)."
  def open(path, mode \\ :read) do
    modes = if mode == :write, do: [:read, :write, :binary, :raw], else: [:read, :binary, :raw]

    with {:ok, io} <- :file.open(path, modes),
         {:ok, fat} <- mount(io) do
      {:ok, fat}
    else
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason) |> to_string()}
      error -> error
    end
  end

  def close(%{io: io}), do: :file.close(io)

  defp mount(io) do
    with {:ok, <<_::binary-size(446), table::binary-size(64), 0x55, 0xAA>>} <-
           :file.pread(io, 0, 512),
         {:ok, lba} <- first_fat(table),
         {:ok, boot} <- :file.pread(io, lba * 512, 512) do
      <<_::binary-size(11), bps::little-16, spc, reserved::little-16, nfats,
        root_entries::little-16, _total16::little-16, _media, fat16::little-16, _::binary-size(8),
        _total32::little-32, fat32::little-32, _::binary-size(4), root_cluster::little-32,
        _::binary>> = boot

      base = lba * 512
      fat_size = if fat16 != 0, do: fat16, else: fat32
      fat_start = base + reserved * bps
      root_start = fat_start + nfats * fat_size * bps
      root_bytes = div(root_entries * 32 + bps - 1, bps) * bps

      {:ok,
       %{
         io: io,
         kind: if(root_entries == 0, do: :fat32, else: :fat16),
         cluster: spc * bps,
         fat_start: fat_start,
         fat_bytes: fat_size * bps,
         nfats: nfats,
         root_start: root_start,
         root_bytes: root_bytes,
         root_cluster: root_cluster,
         data_start: root_start + root_bytes
       }}
    else
      {:ok, _} -> {:error, "a imagem não tem tabela de partições (MBR)"}
      error -> error
    end
  end

  defp first_fat(table) do
    entries =
      for <<_boot, _chs::binary-size(3), type, _::binary-size(3), lba::little-32,
            _n::little-32 <- table>>,
          do: {type, lba}

    case Enum.find(entries, fn {type, lba} -> type in @fat_types and lba > 0 end) do
      {_, lba} -> {:ok, lba}
      nil -> {:error, "nenhuma partição FAT na imagem"}
    end
  end

  @doc "The root folder: `[%{name:, cluster:, size:, dir?:}]`."
  def list(fat) do
    with {:ok, data} <- root(fat), do: {:ok, entries(data, [], [])}
  end

  @doc "The contents of the root file `name` (any case), or `{:error, :enoent}`."
  def read(fat, name) do
    with {:ok, files} <- list(fat),
         %{} = file <-
           Enum.find(files, &(String.downcase(&1.name) == String.downcase(name))) ||
             {:error, :enoent},
         {:ok, data} <- chain(fat, file.cluster) do
      {:ok, binary_part(data, 0, min(file.size, byte_size(data)))}
    end
  end

  @doc """
  Creates the root file `name` (8.3, e.g. `"userconf.txt"`) holding `data`
  — at most one cluster: a free directory slot, a free cluster marked as the
  last of its chain in every FAT copy.
  """
  def create(fat, name, data) when byte_size(data) <= fat.cluster do
    with {:ok, short, lower} <- short_name_of(name),
         {:ok, files} <- list(fat),
         nil <- Enum.find(files, &(String.downcase(&1.name) == String.downcase(name))) || nil,
         {:ok, slot} <- free_slot(fat),
         {:ok, cluster} <- if(data == "", do: {:ok, 0}, else: allocate(fat)),
         :ok <-
           if(cluster > 0,
             do: :file.pwrite(fat.io, cluster_offset(fat, cluster), data),
             else: :ok
           ) do
      entry =
        <<short::binary, 0x20, lower, 0::8, 0::32, 0::16, cluster >>> 16::little-16, 0::32,
          cluster &&& 0xFFFF::little-16, byte_size(data)::little-32>>

      :file.pwrite(fat.io, slot, entry)
    else
      %{} -> {:error, "#{name} já existe na partição de boot"}
      error -> error
    end
  end

  # "userconf.txt" → {"USERCONFTXT", flags}: the NT byte keeps base and
  # extension lower case for Linux and Windows
  defp short_name_of(name) do
    case String.split(name, ".") do
      [base] when byte_size(base) in 1..8 ->
        {:ok, pad(base, 8) <> "   ", lower_flags(base, "")}

      [base, ext] when byte_size(base) in 1..8 and byte_size(ext) in 1..3 ->
        {:ok, pad(base, 8) <> pad(ext, 3), lower_flags(base, ext)}

      _ ->
        {:error, "#{name} não é um nome 8.3"}
    end
  end

  defp pad(s, n), do: s |> String.upcase() |> String.pad_trailing(n)

  defp lower_flags(base, ext) do
    if(base == String.downcase(base), do: 0x08, else: 0) |||
      if(ext != "" and ext == String.downcase(ext), do: 0x10, else: 0)
  end

  # the absolute offset of the first unused 32-byte slot of the root folder
  defp free_slot(fat) do
    offsets =
      case fat.kind do
        :fat16 ->
          Enum.map(0..(div(fat.root_bytes, 32) - 1), &(fat.root_start + &1 * 32))

        :fat32 ->
          for c <- clusters(fat, fat.root_cluster),
              i <- 0..(div(fat.cluster, 32) - 1),
              do: cluster_offset(fat, c) + i * 32
      end

    Enum.find_value(offsets, {:error, "a pasta raiz da partição de boot está cheia"}, fn off ->
      case :file.pread(fat.io, off, 1) do
        {:ok, <<b>>} when b in [0x00, 0xE5] -> {:ok, off}
        _ -> nil
      end
    end)
  end

  defp allocate(fat) do
    {:ok, table} = :file.pread(fat.io, fat.fat_start, fat.fat_bytes)

    {width, eoc, mask} =
      if fat.kind == :fat32, do: {4, 0x0FFFFFFF, 0x0FFFFFFF}, else: {2, 0xFFFF, 0xFFFF}

    count = div(byte_size(table), width)

    case Enum.find(2..(count - 1), &((entry(table, &1, width) &&& mask) == 0)) do
      nil ->
        {:error, "a partição de boot está cheia"}

      c ->
        Enum.each(0..(fat.nfats - 1), fn k ->
          :file.pwrite(
            fat.io,
            fat.fat_start + k * fat.fat_bytes + c * width,
            <<eoc::little-size(width * 8)>>
          )
        end)

        {:ok, c}
    end
  end

  defp entry(table, i, width) do
    table |> binary_part(i * width, width) |> :binary.decode_unsigned(:little)
  end

  defp cluster_offset(fat, c), do: fat.data_start + (c - 2) * fat.cluster

  defp clusters(fat, c) do
    if c < 2 or last?(fat, c) do
      []
    else
      {:ok, n} = next(fat, c)
      [c | clusters(fat, n)]
    end
  end

  defp root(%{kind: :fat16} = fat), do: :file.pread(fat.io, fat.root_start, fat.root_bytes)
  defp root(fat), do: chain(fat, fat.root_cluster)

  defp chain(fat, cluster), do: chain(fat, cluster, [])

  defp chain(fat, cluster, acc) do
    if cluster < 2 or last?(fat, cluster) do
      {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      with {:ok, data} <-
             :file.pread(fat.io, fat.data_start + (cluster - 2) * fat.cluster, fat.cluster),
           {:ok, next} <- next(fat, cluster) do
        chain(fat, next, [data | acc])
      end
    end
  end

  defp next(%{kind: :fat32} = fat, c) do
    with {:ok, <<n::little-32>>} <- :file.pread(fat.io, fat.fat_start + c * 4, 4),
         do: {:ok, n &&& 0x0FFFFFFF}
  end

  defp next(fat, c) do
    with {:ok, <<n::little-16>>} <- :file.pread(fat.io, fat.fat_start + c * 2, 2), do: {:ok, n}
  end

  defp last?(%{kind: :fat32}, c), do: c >= 0x0FFFFFF8
  defp last?(_fat16, c), do: c >= 0xFFF8

  # 32-byte entries; long names come as pieces before their short entry
  defp entries(<<0, _::binary>>, _lfn, acc), do: Enum.reverse(acc)
  defp entries(<<>>, _lfn, acc), do: Enum.reverse(acc)
  defp entries(<<0xE5, _::binary-size(31), rest::binary>>, _lfn, acc), do: entries(rest, [], acc)

  defp entries(
         <<_seq, n1::binary-size(10), 0x0F, _, _sum, n2::binary-size(12), _::16,
           n3::binary-size(4), rest::binary>>,
         lfn,
         acc
       ),
       do: entries(rest, [n1 <> n2 <> n3 | lfn], acc)

  defp entries(
         <<short::binary-size(11), attr, _::binary-size(8), hi::little-16, _::binary-size(4),
           lo::little-16, size::little-32, rest::binary>>,
         lfn,
         acc
       ) do
    name = if lfn == [], do: short_name(short), else: long_name(lfn)

    if (attr &&& 0x08) != 0 do
      # the volume label
      entries(rest, [], acc)
    else
      entry = %{name: name, cluster: hi <<< 16 ||| lo, size: size, dir?: (attr &&& 0x10) != 0}
      entries(rest, [], [entry | acc])
    end
  end

  defp short_name(<<base::binary-size(8), ext::binary-size(3)>>) do
    base = String.trim_trailing(base)
    ext = String.trim_trailing(ext)
    if ext == "", do: base, else: base <> "." <> ext
  end

  # the pieces were collected last first, which is the name's order
  defp long_name(pieces) do
    pieces
    |> IO.iodata_to_binary()
    |> :unicode.characters_to_binary({:utf16, :little})
    |> String.split(<<0>>)
    |> List.first()
  end
end
