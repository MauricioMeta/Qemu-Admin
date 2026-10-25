defmodule QemuAdmin.VmStore do
  @moduledoc """
  The VM definitions on disk: one folder per VM under
  `QemuAdmin.Paths.vms_dir/0`, named by its id, holding `vm.json`, the disks
  created with it, the UEFI variables and `qemu.log`.

  Every change is broadcast on `QemuAdmin.topic/0` as `{:vms_changed, id}`.
  """

  alias QemuAdmin.{Paths, Vm}
  alias QemuAdmin.Esp32.Flash
  alias QemuAdmin.Qemu.Img

  @file_name "vm.json"
  @flash %{"path" => "flash.bin", "format" => "raw", "interface" => "mtd"}

  @doc "Every VM, by name."
  def list do
    Paths.vms_dir()
    |> Path.join("*/" <> @file_name)
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read(path) do
        {:ok, vm} -> [vm]
        _ -> []
      end
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def get(id) when is_binary(id) do
    if safe_id?(id), do: read(Path.join(Paths.vm_dir(id), @file_name)), else: {:error, :not_found}
  end

  def get(_), do: {:error, :not_found}

  defp read(path) do
    with {:ok, json} <- File.read(path),
         {:ok, map} <- Jason.decode(json) do
      vm = Vm.from_map(map)
      # the folder is the id: a copied folder is its own VM
      {:ok, %{vm | id: path |> Path.dirname() |> Path.basename()}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Writes `vm.json`."
  def save(%Vm{id: id} = vm) when is_binary(id) do
    dir = Paths.vm_dir(id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, @file_name), Jason.encode_to_iodata!(vm, pretty: true))
    broadcast(id)
    {:ok, vm}
  end

  @doc """
  Creates a VM from the form's params: picks its id, writes it and, with
  `disk_size` (`"40G"`), creates its first disk (`disk0.qcow2`). An ESP32
  gets its blank flash instead (`flash.bin`, `flash_size` MiB, 4 by default);
  an Arduino and a Raspberry Pi start empty (their program, their SD card
  image come after).
  """
  def create(params, settings \\ %{}) do
    params =
      case Vm.kind(params["arch"] || "", params["machine"] || "") do
        :esp32 -> Map.put(params, "disks", %{"0" => @flash})
        :pc -> params
        _board -> Map.put(params, "disks", %{})
      end

    with {:ok, vm} <- Vm.cast(Vm.new(settings), params) do
      id = unique_id(vm.name)
      vm = %{vm | id: id, created_at: DateTime.utc_now() |> DateTime.truncate(:second)}

      created =
        case Vm.kind(vm) do
          :esp32 -> create_flash(vm, params["flash_size"] || "4")
          :pc -> maybe_disk(vm, params["disk_size"], params["disk_format"] || "qcow2")
          _board -> {:ok, vm}
        end

      with {:ok, vm} <- created do
        save(vm)
      end
    end
  end

  defp create_flash(vm, mib) do
    with {n, ""} <- Integer.parse(String.trim(to_string(mib))),
         :ok <- Flash.create(Path.join(Paths.vm_dir(vm.id), @flash["path"]), n) do
      {:ok, vm}
    else
      error ->
        File.rm_rf(Paths.vm_dir(vm.id))
        msg = with({:error, m} <- error, do: m, else: (_ -> "tamanho de flash inválido"))
        {:error, [flash_size: msg]}
    end
  end

  defp maybe_disk(vm, size, format) when is_binary(size) and size != "" do
    ext = if format == "raw", do: "img", else: format
    name = "disk0.#{ext}"

    case Img.create(Path.join(Paths.vm_dir(vm.id), name), format, size) do
      {:ok, _} ->
        interface = params_interface(vm)

        {:ok,
         %{
           vm
           | disks: vm.disks ++ [%{"path" => name, "format" => format, "interface" => interface}]
         }}

      {:error, msg} ->
        File.rm_rf(Paths.vm_dir(vm.id))
        {:error, [disk_size: msg]}
    end
  end

  defp maybe_disk(vm, _size, _format), do: {:ok, vm}

  # Windows installers have no VirtIO driver: a disk they would not see is
  # the most common first-boot failure, so the first disk of a VM booting a
  # Windows ISO is SATA. Everything else gets VirtIO.
  defp params_interface(vm) do
    if vm.cdrom =~ ~r/win/i, do: "sata", else: "virtio"
  end

  @doc "Copies a VM (definition and folder, disks included) under a new name."
  def clone(%Vm{} = vm, name) do
    id = unique_id(name)
    File.cp_r!(Paths.vm_dir(vm.id), Paths.vm_dir(id))
    File.rm(Path.join(Paths.vm_dir(id), "qemu.log"))
    File.rm(Path.join(Paths.vm_dir(id), "screen.png"))
    File.rm(Path.join(Paths.vm_dir(id), "serial.log"))
    save(%{vm | id: id, name: name, created_at: DateTime.utc_now() |> DateTime.truncate(:second)})
  end

  @doc """
  Removes a VM. Its folder (with the disks inside it) goes too; disks kept
  elsewhere are never touched.
  """
  def delete(id) do
    if safe_id?(id) do
      File.rm_rf!(Paths.vm_dir(id))
      broadcast(id)
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "A folder name from `name`, not yet taken: \"Windows 11!\" → \"windows-11\"."
  def unique_id(name) do
    base =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "vm"
        slug -> String.slice(slug, 0, 40)
      end

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not File.exists?(Paths.vm_dir(&1))))
  end

  # ids come back from the page: never let one climb out of vms_dir
  defp safe_id?(id),
    do: Regex.match?(~r/^[a-z0-9][a-z0-9\-_.]*$/i, id) and not String.contains?(id, "..")

  defp broadcast(id) do
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, QemuAdmin.topic(), {:vms_changed, id})
  end
end
