defmodule QemuAdmin.Qemu.Img do
  @moduledoc """
  `qemu-img`: creates, describes and resizes disk images.

  Sizes are QEMU's own strings (`"40G"`, `"512M"`) going in and bytes coming
  out (`info/1`).
  """

  alias QemuAdmin.Qemu

  @formats ~w(qcow2 raw vhdx vmdk vdi vpc)
  @doc "The image formats the app offers."
  def formats, do: @formats

  @doc "The file extensions of a disk image."
  def extensions, do: ~w(.qcow2 .img .raw .vhdx .vhd .vmdk .vdi)

  @doc "Whether `size` is something qemu-img accepts (`40G`, `512M`, `1T`, bytes)."
  def valid_size?(size), do: is_binary(size) and Regex.match?(~r/^\d+(\.\d+)?[KMGT]?$/i, size)

  @doc "Creates `path` of `format` and `size`."
  def create(path, format, size) when format in @formats do
    cond do
      not valid_size?(size) ->
        {:error, "tamanho inválido: #{inspect(size)} (ex.: 40G, 512M)"}

      File.exists?(path) ->
        {:error, "#{path} já existe"}

      true ->
        File.mkdir_p!(Path.dirname(path))
        run(["create", "-f", format, path, String.upcase(size)])
    end
  end

  def create(_path, format, _size), do: {:error, "formato desconhecido: #{format}"}

  @doc """
  `{:ok, %{format:, virtual_size:, actual_size:, backing:}}` from
  `qemu-img info --output=json`.
  """
  def info(path) do
    # -U: also on an image a running VM holds locked
    with {:ok, out} <- run(["info", "-U", "--output=json", path]),
         {:ok, json} <- Jason.decode(out) do
      {:ok,
       %{
         format: json["format"],
         virtual_size: json["virtual-size"],
         actual_size: json["actual-size"],
         backing: json["backing-filename"]
       }}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "resposta inesperada do qemu-img"}
      error -> error
    end
  end

  @doc "Grows (or, with `shrink: true`, shrinks) `path` to `size` (`+10G` grows by)."
  def resize(path, size, opts \\ []) do
    shrink = if opts[:shrink], do: ["--shrink"], else: []

    if Regex.match?(~r/^[+-]?\d+(\.\d+)?[KMGT]?$/i, size),
      do: run(["resize"] ++ shrink ++ [path, String.upcase(size)]),
      else: {:error, "tamanho inválido: #{inspect(size)}"}
  end

  @doc "Converts `source` into a new image `target` of `format`."
  def convert(source, target, format) when format in @formats do
    run(["convert", "-p", "-O", format, source, target])
  end

  defp run(args) do
    with {:ok, exe} <- Qemu.exe("qemu-img") do
      case System.cmd(exe, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, _} -> {:error, String.trim(out)}
      end
    else
      {:error, :no_qemu} -> {:error, "QEMU não encontrado"}
      {:error, _} -> {:error, "qemu-img não encontrado"}
    end
  end

  @doc "1610612736 → \"1.5 GiB\"."
  def human(nil), do: "—"

  def human(bytes) when is_integer(bytes) do
    {value, unit} =
      Enum.reduce_while([{"TiB", 40}, {"GiB", 30}, {"MiB", 20}, {"KiB", 10}], {bytes, "B"}, fn {u,
                                                                                                p},
                                                                                               acc ->
        if bytes >= Bitwise.bsl(1, p),
          do: {:halt, {bytes / Bitwise.bsl(1, p), u}},
          else: {:cont, acc}
      end)

    if unit == "B",
      do: "#{bytes} B",
      else: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)} #{unit}"
  end
end
