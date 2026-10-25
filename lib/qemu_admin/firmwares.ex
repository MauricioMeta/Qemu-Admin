defmodule QemuAdmin.Firmwares do
  @moduledoc """
  The programs a VM can run, for the tree on the side panel: pick a VM and one of
  its firmwares and simulate.

  A VM's firmwares are the files of its folder that the board can load: the legacy
  `firmware.elf` / `firmware.bin` at the top and whatever is in its `firmware/`
  folder. What is loaded is the **active** one: the `program` the VM names
  (`QemuAdmin.Vm`, relative to its folder), else the legacy file. Only the
  microcontrollers have firmwares (an Arduino, a Cortex-M board, a Renode board);
  to a PC or a Raspberry Pi the list is empty.
  """

  alias QemuAdmin.Vm

  @folder "firmware"
  @legacy ~w(firmware.elf firmware.bin firmware.hex)

  @doc "The folder the VM's firmwares are kept in."
  def folder(vm), do: Path.join(Vm.dir(vm), @folder)

  @doc "The file extensions the VM's board loads."
  def extensions(vm) do
    case Vm.kind(vm) do
      :renode -> ~w(.elf .hex .axf)
      :avr -> ~w(.elf .bin)
      :cortexm -> ~w(.elf .bin)
      _ -> []
    end
  end

  @doc "Whether the VM has firmwares at all."
  def supported?(vm), do: extensions(vm) != []

  @doc """
  The firmwares: `[%{file:, name:, size:, active?:}]`, `file` relative to the VM's
  folder, the active one marked.
  """
  def list(vm) do
    exts = extensions(vm)
    active = active_file(vm, exts)

    files =
      if exts == [] do
        []
      else
        top = for name <- @legacy, File.regular?(Path.join(Vm.dir(vm), name)), do: name
        inner = for p <- sorted(Path.wildcard(Path.join(folder(vm), "*"))), do: Path.join(@folder, Path.basename(p))

        Enum.filter(top ++ inner, fn f ->
          File.regular?(Path.join(Vm.dir(vm), f)) and ext(f) in exts
        end)
      end

    for f <- files do
      %{
        file: f,
        name: Path.basename(f),
        size: File.stat!(Path.join(Vm.dir(vm), f)).size,
        active?: f == active
      }
    end
  end

  defp sorted(paths), do: Enum.sort_by(paths, &String.downcase/1)
  defp ext(file), do: file |> Path.extname() |> String.downcase()

  @doc "The relative name of the file the VM runs, or nil."
  def active(vm), do: active_file(vm, extensions(vm))

  @doc "The absolute path of the file the VM runs, or nil."
  def path(vm) do
    case active(vm) do
      nil -> nil
      file -> Path.join(Vm.dir(vm), file)
    end
  end

  defp active_file(vm, exts) do
    program = vm.program || ""

    cond do
      exts == [] ->
        nil

      program != "" and ext(program) in exts and File.regular?(Path.join(Vm.dir(vm), program)) ->
        program

      true ->
        # the legacy names go by what the board loads: .hex only where it is understood
        Enum.find(@legacy, fn n ->
          ext(n) in exts and File.regular?(Path.join(Vm.dir(vm), n))
        end)
    end
  end

  @doc "Copies `src` into the VM's firmware folder; `{:ok, file}` (relative) or `{:error, msg}`."
  def add(vm, src) do
    name = Path.basename(src)

    cond do
      ext(name) not in extensions(vm) ->
        {:error, "formato #{ext(name)} não serve a esta VM (aceita #{Enum.join(extensions(vm), ", ")})"}

      true ->
        File.mkdir_p!(folder(vm))

        case File.cp(src, Path.join(folder(vm), name)) do
          :ok -> {:ok, Path.join(@folder, name)}
          {:error, reason} -> {:error, "#{src}: #{:file.format_error(reason)}"}
        end
    end
  end
end
