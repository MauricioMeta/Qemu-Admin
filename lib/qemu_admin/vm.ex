defmodule QemuAdmin.Vm do
  @moduledoc """
  A virtual machine's definition — what `vm.json` holds and what the
  Configuração form edits. Pure: building its command line is
  `QemuAdmin.Vm.Args`, keeping it on disk `QemuAdmin.VmStore`, running it
  `QemuAdmin.VmServer`.

  Disk paths may be relative: they are then inside the VM's folder
  (`resolve/2`), so a VM folder can be moved or copied whole.

  `cast/2` takes the form's params (string keys) over a VM and returns
  `{:ok, vm}` or `{:error, errors}`, `errors` being `[{field, message}]`.

  Besides PCs, a VM can be a development board (`QemuAdmin.Board`, by its
  machine; `kind/1`):

    * an **ESP32** (`xtensa`), run by Espressif's QEMU: the board is the
      chip (`esp32`, `esp32s3`), `memory` its PSRAM in MiB (0 for none), its
      one disk the SPI flash (`flash.bin`, raw, `interface` `mtd`);
    * an **Arduino** (`avr`): its program, `firmware.elf` or `firmware.bin`
      in the VM's folder, is the board's flash; no disk, no network;
    * a **Raspberry Pi** (`raspi*` machines of `aarch64` and `arm`): a
      kernel, its device tree and command line (`kernel`, `dtb`, `append`,
      taken from the SD card image when it is imported) and the SD card as
      its one disk (raw, `interface` `sd`); its memory is the board's;
    * a **Cortex-M board** (`cortexm`: the STM32 ones, as the Netduino Plus
      2): its program, `firmware.elf` or `firmware.bin` in the VM's folder,
      is loaded with `-kernel`; no disk, no network, no screen.

  The ESP32, the Arduino and the Cortex-M boards are microcontrollers
  (`mcu?/1`): their console is the UART. A Raspberry Pi has a screen and a UART (`serial?/1`).
  `firmware` and `app` remember what was last written (AtomVM's version,
  the `.avm`, the Arduino's program), for the page. What a PC has and a
  board has not — CD, UEFI, video card, a choice of accelerator — is fixed
  by `cast/2`.
  """

  alias QemuAdmin.Qemu.Img

  @derive {Jason.Encoder, except: []}
  defstruct id: nil,
            name: "",
            arch: "x86_64",
            machine: "q35",
            cpu: "max",
            cpus: 2,
            memory: 2048,
            accel: "auto",
            display: "vnc",
            vga: "std",
            uefi: false,
            localtime: false,
            boot: "disk",
            cdrom: "",
            disks: [],
            net_mode: "user",
            net_model: "virtio-net-pci",
            forwards: [],
            usb_tablet: true,
            extra_args: "",
            notes: "",
            firmware: "",
            app: "",
            kernel: "",
            dtb: "",
            append: "",
            created_at: nil

  @type t :: %__MODULE__{}

  @machines %{
    "x86_64" => ~w(q35 pc microvm),
    "i386" => ~w(pc q35 isapc),
    "aarch64" => ~w(virt sbsa-ref raspi3b raspi3ap raspi4b),
    "arm" => ~w(raspi2b raspi0 netduinoplus2),
    "xtensa" => ~w(esp32 esp32s3),
    "avr" => ~w(arduino-uno arduino-mega-2560-v3 arduino-mega)
  }

  def machines(arch), do: Map.get(@machines, arch, [])
  def default_machine(arch), do: arch |> machines() |> List.first()

  # the Cortex-M machines of `qemu-system-arm` the app configures
  @cortexm ~w(netduinoplus2)

  @doc "The Cortex-M (STM32) machines the app configures."
  def cortexm_machines, do: @cortexm

  @doc "`:pc`, `:esp32`, `:avr` (an Arduino), `:cortexm` or `:raspi`."
  def kind(%__MODULE__{arch: arch, machine: machine}), do: kind(arch, machine)

  def kind("xtensa", _machine), do: :esp32
  def kind("avr", _machine), do: :avr
  def kind("arm", machine) when machine in @cortexm, do: :cortexm
  def kind(_arch, "raspi" <> _), do: :raspi
  def kind(_arch, _machine), do: :pc

  @doc "Whether the VM (or architecture) is a microcontroller — an ESP32, an Arduino or a Cortex-M board."
  def mcu?(%__MODULE__{} = vm), do: kind(vm) in [:esp32, :avr, :cortexm]
  def mcu?(arch), do: arch in ["xtensa", "avr"]

  @doc "Whether the VM has a UART the page shows (every board)."
  def serial?(%__MODULE__{} = vm), do: kind(vm) != :pc

  @doc "The development board the VM is (`QemuAdmin.Board`), or nil for a PC."
  def board(%__MODULE__{machine: machine}), do: QemuAdmin.Board.for_machine(machine)

  @doc "The defaults a VM takes when it changes kind (MiB of PSRAM are not MiB of RAM)."
  def kind_defaults(:esp32, _machine), do: %{memory: 4, cpus: 2, net_model: "open_eth"}
  def kind_defaults(:avr, _machine), do: %{memory: 0, cpus: 1, net_model: "none"}
  def kind_defaults(:cortexm, _machine), do: %{memory: 0, cpus: 1, net_model: "none"}

  def kind_defaults(:raspi, machine) do
    %{memory: QemuAdmin.Board.for_machine(machine).memory, cpus: 4, net_model: "usb-net"}
  end

  def kind_defaults(:pc, _machine), do: %{memory: 2048, cpus: 2, net_model: "virtio-net-pci"}

  def machine_label(m) do
    case QemuAdmin.Board.for_machine(m) do
      nil -> m
      board -> "#{board.name} — #{board.chip}"
    end
  end

  def accels, do: ~w(auto tcg whpx kvm hvf)
  def displays, do: ~w(vnc sdl gtk none)
  def vgas, do: ~w(std virtio qxl cirrus vmware none)
  def boots, do: ~w(disk cdrom)
  def net_modes, do: ~w(user none)
  def net_models, do: ~w(virtio-net-pci e1000 e1000e rtl8139 vmxnet3 open_eth usb-net none)
  def interfaces, do: ~w(virtio sata nvme mtd sd)

  def display_label("vnc"), do: "Console no app (VNC)"
  def display_label("sdl"), do: "Janela SDL"
  def display_label("gtk"), do: "Janela GTK"
  def display_label("none"), do: "Sem tela"
  def display_label(other), do: other

  def interface_label("virtio"), do: "VirtIO (rápido; Windows precisa de driver)"
  def interface_label("sata"), do: "SATA/IDE (compatível)"
  def interface_label("nvme"), do: "NVMe"
  def interface_label("mtd"), do: "Flash SPI (ESP32)"
  def interface_label("sd"), do: "Cartão SD (Raspberry Pi)"
  def interface_label(other), do: other

  @doc "A blank VM with the user's defaults (`QemuAdmin.Settings`)."
  def new(settings \\ %{}) do
    %__MODULE__{
      accel: Map.get(settings, :default_accel, "auto"),
      display: Map.get(settings, :default_display, "vnc")
    }
  end

  @doc "The VM's folder."
  def dir(%__MODULE__{id: id}), do: QemuAdmin.Paths.vm_dir(id)

  @doc "An absolute path for `path`, relative ones taken inside the VM's folder."
  def resolve(_vm, nil), do: nil
  def resolve(_vm, ""), do: nil

  def resolve(vm, path) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(dir(vm), path)
    end
  end

  @doc "Back from JSON (string keys); unknown keys are dropped."
  def from_map(map) when is_map(map) do
    fields = __struct__() |> Map.from_struct() |> Map.keys() |> Map.new(&{to_string(&1), &1})

    attrs =
      for {k, v} <- map, field = fields[to_string(k)], into: %{} do
        {field, v}
      end

    vm = struct(__MODULE__, attrs)
    %{vm | disks: Enum.map(vm.disks || [], &disk_from_map/1), forwards: vm.forwards || []}
  end

  defp disk_from_map(d) do
    %{
      "path" => d["path"] || d[:path] || "",
      "format" => d["format"] || d[:format] || "qcow2",
      "interface" => d["interface"] || d[:interface] || "virtio"
    }
  end

  @doc """
  Applies the form's `params` to `vm`. Disks come as
  `"disks" => %{"0" => %{"path", "format", "interface"}}` and port forwards as
  one per line (`tcp:2222:22`).
  """
  def cast(%__MODULE__{} = vm, params) do
    vm = %{
      vm
      | name: str(params, "name", vm.name),
        arch: str(params, "arch", vm.arch),
        machine: str(params, "machine", vm.machine),
        cpu: str(params, "cpu", vm.cpu),
        cpus: int(params, "cpus", vm.cpus),
        memory: int(params, "memory", vm.memory),
        accel: str(params, "accel", vm.accel),
        display: str(params, "display", vm.display),
        vga: str(params, "vga", vm.vga),
        uefi: bool(params, "uefi", vm.uefi),
        localtime: bool(params, "localtime", vm.localtime),
        boot: str(params, "boot", vm.boot),
        cdrom: str(params, "cdrom", vm.cdrom),
        disks: disks(params, vm.disks),
        net_mode: str(params, "net_mode", vm.net_mode),
        net_model: str(params, "net_model", vm.net_model),
        forwards: forwards(params, vm.forwards),
        usb_tablet: bool(params, "usb_tablet", vm.usb_tablet),
        extra_args: str(params, "extra_args", vm.extra_args),
        kernel: str(params, "kernel", vm.kernel),
        dtb: str(params, "dtb", vm.dtb),
        append: str(params, "append", vm.append),
        notes: Map.get(params, "notes", vm.notes) || ""
    }

    # aarch64 has no SeaBIOS: it only boots UEFI.
    vm = if vm.arch == "aarch64", do: %{vm | uefi: true}, else: vm

    vm =
      if vm.machine in machines(vm.arch), do: vm, else: %{vm | machine: default_machine(vm.arch)}

    vm =
      case kind(vm) do
        :esp32 -> as_esp32(vm, Map.has_key?(params, "memory"))
        :avr -> as_avr(vm)
        :cortexm -> as_cortexm(vm)
        :raspi -> as_raspi(vm)
        :pc -> vm
      end

    case validate(vm) do
      [] -> {:ok, vm}
      errors -> {:error, errors}
    end
  end

  # What no board has: a CD, UEFI, a video card, a choice of accelerator
  # (TCG only: there is no hypervisor for these CPUs on a PC).
  defp as_board(vm) do
    %{vm | accel: "tcg", vga: "none", uefi: false, boot: "disk", cdrom: "", cpu: ""}
  end

  # A chip has one flash, one UART, no screen or USB. A PC's memory (MiB of
  # RAM) left over from the defaults becomes the chip's usual 4 MiB of PSRAM.
  defp as_esp32(vm, memory_given?) do
    memory =
      if memory_given? or vm.memory in 0..16,
        do: vm.memory,
        else: kind_defaults(:esp32, vm.machine).memory

    %{
      as_board(vm)
      | memory: memory,
        display: "none",
        cpus: 2,
        usb_tablet: false,
        net_model: "open_eth",
        disks: Enum.map(vm.disks, &%{&1 | "format" => "raw", "interface" => "mtd"})
    }
  end

  # A Cortex-M board is its program and its UART, like an Arduino: no disk, no
  # network (the Netduino Plus 2's Ethernet is not modelled by QEMU).
  defp as_cortexm(vm), do: as_avr(vm)

  # An Arduino is its program and its UART: no disk, no network.
  defp as_avr(vm) do
    %{
      as_board(vm)
      | memory: 0,
        display: "none",
        cpus: 1,
        usb_tablet: false,
        net_mode: "none",
        net_model: "none",
        disks: []
    }
  end

  # A Raspberry Pi has the board's memory and cores, the SD card as its disk
  # and, on the boards QEMU gives USB, a USB network adapter.
  defp as_raspi(vm) do
    board = board(vm)

    %{
      as_board(vm)
      | memory: board.memory,
        cpus: if(board.id == "raspi0", do: 1, else: 4),
        usb_tablet: board.usb?,
        net_model: if(board.usb?, do: "usb-net", else: "none"),
        net_mode: if(board.usb?, do: vm.net_mode, else: "none"),
        disks: Enum.map(vm.disks, &%{&1 | "format" => "raw", "interface" => "sd"})
    }
  end

  @doc "`[{field, message}]` of what is wrong with `vm`."
  def validate(vm) do
    []
    |> check(String.trim(vm.name) == "", :name, "dê um nome à VM")
    |> check(vm.arch not in QemuAdmin.Qemu.arches(), :arch, "arquitetura desconhecida")
    |> check(not is_integer(vm.cpus) or vm.cpus < 1 or vm.cpus > 256, :cpus, "de 1 a 256")
    |> check(
      kind(vm) == :pc and (not is_integer(vm.memory) or vm.memory < 16),
      :memory,
      "pelo menos 16 MiB"
    )
    |> check(
      kind(vm) == :esp32 and (not is_integer(vm.memory) or vm.memory not in 0..16),
      :memory,
      "PSRAM de 0 a 16 MiB"
    )
    |> check(
      kind(vm) == :esp32 and length(vm.disks) != 1,
      :disks,
      "o ESP32 tem exatamente uma flash"
    )
    |> check(
      kind(vm) == :raspi and length(vm.disks) > 1,
      :disks,
      "o Raspberry Pi tem um cartão SD"
    )
    |> check(vm.accel not in accels(), :accel, "aceleração desconhecida")
    |> check(vm.display not in displays(), :display, "tela desconhecida")
    |> check(vm.vga not in vgas(), :vga, "placa de vídeo desconhecida")
    |> check(vm.boot not in boots(), :boot, "boot desconhecido")
    |> check(vm.net_mode not in net_modes(), :net_mode, "rede desconhecida")
    |> check(vm.net_model not in net_models(), :net_model, "placa de rede desconhecida")
    |> check(
      Enum.any?(vm.disks, &(&1["format"] not in Img.formats())),
      :disks,
      "formato de disco desconhecido"
    )
    |> check(
      Enum.any?(vm.disks, &(&1["interface"] not in interfaces())),
      :disks,
      "interface de disco desconhecida"
    )
    |> check(
      Enum.any?(vm.forwards, &(parse_forward(&1) == :error)),
      :forwards,
      "use proto:porta_host:porta_vm, ex. tcp:2222:22"
    )
    |> check(match?({:error, _}, split_args(vm.extra_args)), :extra_args, "aspas desbalanceadas")
    |> Enum.reverse()
  end

  defp check(errors, true, field, msg), do: [{field, msg} | errors]
  defp check(errors, false, _field, _msg), do: errors

  @doc ~S|"tcp:2222:22" → {:ok, {"tcp", 2222, 22}}|
  def parse_forward(spec) do
    case String.split(String.trim(spec), ":") do
      [proto, host, guest] when proto in ["tcp", "udp"] ->
        with {h, ""} when h in 1..65_535 <- Integer.parse(host),
             {g, ""} when g in 1..65_535 <- Integer.parse(guest) do
          {:ok, {proto, h, g}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc "The extra arguments, split as a shell would (quotes respected)."
  def split_args(nil), do: {:ok, []}

  def split_args(text) do
    if text |> String.graphemes() |> Enum.count(&(&1 == "\"")) |> rem(2) == 1,
      do: {:error, :quotes},
      else: {:ok, OptionParser.split(text)}
  end

  @doc "A MAC address that stays the same for the VM (52:54:00 is QEMU's prefix)."
  def mac(%__MODULE__{id: id}) do
    <<a, b, c, _::binary>> = :crypto.hash(:sha256, id || "")

    "52:54:00:" <>
      Enum.map_join(
        [a, b, c],
        ":",
        &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
      )
  end

  defp str(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, v} when is_binary(v) -> String.trim(v)
      _ -> default
    end
  end

  defp int(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, v} when is_integer(v) ->
        v

      {:ok, v} when is_binary(v) ->
        with({n, ""} <- Integer.parse(String.trim(v)), do: n, else: (_ -> nil))

      _ ->
        default
    end
  end

  # A checkbox: present ("true"/"on") or the hidden "false" before it.
  defp bool(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, v} when v in [true, "true", "on"] -> true
      {:ok, v} when v in [false, "false"] -> false
      _ -> default
    end
  end

  defp disks(%{"disks" => disks}, _default) when is_map(disks) do
    disks
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(fn {_, d} -> disk_from_map(d) end)
    |> Enum.reject(&(String.trim(&1["path"]) == ""))
    |> Enum.map(&Map.update!(&1, "path", fn p -> String.trim(p) end))
  end

  defp disks(_params, default), do: default

  defp forwards(%{"forwards" => text}, _default) when is_binary(text) do
    text
    |> String.split(~r/[\r\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp forwards(_params, default), do: default
end
