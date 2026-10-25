defmodule QemuAdminWeb.AdminLive do
  @moduledoc """
  The whole app, in the Rockwell Viewer shell: icon rail on the left
  (`App.Sidebar`), a resizable side panel, the main area with its own header
  bar and the open VMs' tabs, and the status footer. In the desktop window an
  app-drawn title bar sits on top (`App.TitleBar`).

  The rail's views:

    * **Máquinas virtuais** — the side panel shows the workspace (switch,
      open a folder) and lists its VMs; the main area is the grid of all of
      them, the Nova VM form, or one VM with its views: Visão geral, Console
      (noVNC), Configuração and Log. A development board (`Vm.kind/1`) adds
      Serial (its UART) and Placa (the board drawn with its pins live), and
      what its program lives in: an ESP32's Flash, an Arduino's Firmware, a
      Raspberry Pi's Cartão SD;
    * **Discos** — every disk image, create and grow;
    * **Imagens** — the workspace's image library and the catalog to
      download from;
    * **QEMU** — which QEMU is in use, and the portable download;
    * **Configurações** — the side panel turns into the sections.

  VMs run in `QemuAdmin.VmServer` processes, so a reload (or a second
  window) finds them as they are: this page only reads the runtime table and
  listens on PubSub.
  """

  use Surface.LiveView

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.Layouts, only: [flash_group: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.{
    Gpio,
    Images,
    Paths,
    Qemu,
    Session,
    Settings,
    Vm,
    VmServer,
    VmStore,
    VmSupervisor,
    Workspace
  }

  alias QemuAdmin.Avr.Firmware, as: AvrFirmware
  alias QemuAdmin.CortexM.Firmware, as: CortexMFw
  alias QemuAdmin.Esp32.AtomVM
  alias QemuAdmin.Raspi.Image, as: RaspiImage
  alias QemuAdmin.Esp32.Flash, as: EspFlash
  alias QemuAdmin.Qemu.{Img, InstallJob}
  alias QemuAdmin.Terminal, as: TermTools
  alias QemuAdmin.Terminal.{Catalog, Groups, Macro, Saved}
  alias QemuAdmin.Vm.Args
  alias QemuAdminWeb.Files

  alias QemuAdminWeb.Components.App.{
    CloseDialog,
    Footer,
    IconButton,
    PageHeader,
    Sidebar,
    Tabs,
    TitleBar
  }

  alias QemuAdminWeb.Components.Files.Picker
  alias QemuAdminWeb.Components.Pages.{Disks, SettingsNav}
  alias QemuAdminWeb.Components.Pages.Commands, as: CommandsPage
  alias QemuAdminWeb.Components.Pages.Images, as: ImagesPage
  alias QemuAdminWeb.Components.Pages.Qemu, as: QemuPage
  alias QemuAdminWeb.Components.Pages.Settings, as: SettingsPage

  alias QemuAdminWeb.Components.Vm.{
    Console,
    CortexFirmware,
    Firmware,
    Flash,
    Form,
    Grid,
    Io,
    Log,
    Overview,
    SdCard,
    SerialConsole,
    StatusDot,
    Terminal
  }

  alias QemuAdminWeb.Components.Vm.List, as: VmList

  # daisyUI's built-in themes, plus ours first — the rail's swatch menu.
  @themes ~w(qemu dark light night dim business coffee forest dracula synthwave cyberpunk
             luxury black corporate nord emerald cupcake winter lofi pastel retro valentine
             halloween garden aqua fantasy wireframe cmyk autumn acid lemonade sunset caramellatte
             abyss silk)

  @overview {"overview", "Visão geral", "hero-squares-2x2"}
  @config {"config", "Configuração", "hero-adjustments-horizontal"}
  @log {"log", "Log", "hero-document-text"}
  @board_view {"io", "Placa", "hero-light-bulb"}

  # each kind of VM's views, in tab order
  @views %{
    pc: [@overview, {"console", "Console", "hero-tv"}, @config, @log],
    esp32: [
      @overview,
      {"console", "Serial", "hero-command-line"},
      @board_view,
      {"flash", "Flash", "hero-cpu-chip"},
      @config,
      @log
    ],
    avr: [
      @overview,
      {"console", "Serial", "hero-command-line"},
      @board_view,
      {"firmware", "Firmware", "hero-cpu-chip"},
      @config,
      @log
    ],
    cortexm: [
      @overview,
      {"console", "Serial", "hero-command-line"},
      {"firmware", "Firmware", "hero-cpu-chip"},
      @config,
      @log
    ],
    renode: [
      @overview,
      {"console", "Serial", "hero-command-line"},
      @config,
      @log
    ],
    raspi: [
      @overview,
      {"console", "Tela", "hero-tv"},
      {"serial", "Serial", "hero-command-line"},
      @board_view,
      {"sd", "Cartão SD", "hero-circle-stack"},
      @config,
      @log
    ]
  }

  @view_labels %{
    "vms" => "Máquinas virtuais",
    "disks" => "Discos",
    "images" => "Imagens",
    "qemu" => "QEMU",
    "commands" => "Comandos",
    "settings" => "Configurações"
  }

  @log_limit 1_000
  @cmd_limit 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, "qemu")
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, "settings")
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, "images")
      :timer.send_interval(5_000, :tick)
    end

    {:ok,
     socket
     |> assign(
       page_title: "QEMU Admin",
       themes: @themes,
       sidebar_expanded: false,
       view: "vms",
       filter: "",
       selected: nil,
       tabs: [],
       tab_views: %{},
       vm_view: "overview",
       mode: nil,
       params: %{},
       errors: %{},
       submitted: false,
       picker: nil,
       disk_info: %{},
       images: [],
       image_download: Images.state(),
       workspaces: Workspace.list(),
       gpio: nil,
       sd_import: %{busy: false, error: nil},
       sd_user: %{"user" => "pi", "password" => "raspberry", "ssh" => "true"},
       command: nil,
       qemu: Qemu.info(),
       install: InstallJob.state(:qemu),
       install_esp: InstallJob.state(:esp),
       esp_flash: nil,
       atomvm: %{releases: nil, error: nil, busy: false},
       flash_offset: "0x0",
       serial_tail: [],
       settings: Settings.all(),
       settings_section: :qemu,
       close: nil,
       log_seq: 0,
       cmds_open: true,
       cmd_history: [],
       cmd_groups: %{},
       lp: nil,
       tree_open: [],
       saved: [],
       cp: %{editing: nil, error: nil},
       cp_commands: [],
       cp_file_error: nil,
       cat: blank_cat()
     )
     |> stream_configure(:log, dom_id: &"log-#{&1.id}")
     |> stream(:log, [])
     |> stream_configure(:cmds, dom_id: &"cmd-#{&1.seq}")
     |> stream(:cmds, [])
     |> load_vms()
     |> restore_session()
     |> attach_hook(:session, :after_render, &save_session/1)}
  end

  # ------------------------------------------------------------ navigation

  @impl true
  def handle_event("nav", %{"view" => "vms"}, socket) do
    # the rail item again, from a VM: back to the grid
    socket =
      if socket.assigns.view == "vms",
        do: assign(socket, selected: nil, mode: nil),
        else: assign(socket, view: "vms")

    {:noreply, socket}
  end

  def handle_event("nav", %{"view" => "disks"}, socket),
    do:
      {:noreply, socket |> assign(view: "disks", mode: nil) |> load_disk_info(all_disks(socket))}

  def handle_event("nav", %{"view" => "images"}, socket),
    do: {:noreply, socket |> assign(view: "images", mode: nil) |> load_images()}

  def handle_event("nav", %{"view" => "qemu"}, socket),
    do:
      {:noreply,
       assign(socket,
         view: "qemu",
         mode: nil,
         qemu: Qemu.info(),
         install: InstallJob.state(:qemu),
         install_esp: InstallJob.state(:esp)
       )}

  def handle_event("nav", %{"view" => "commands"}, socket),
    do: {:noreply, socket |> assign(view: "commands", mode: nil) |> load_commands()}

  # The Terminal's "linha de partida editada" badge: the Comandos page, on that tab.
  def handle_event("open_launch", _params, socket) do
    {:noreply,
     socket
     |> update(:cat, &%{&1 | kind: "launch"})
     |> assign(view: "commands", mode: nil)
     |> load_commands()}
  end

  def handle_event("nav", %{"view" => "settings"}, socket),
    do: {:noreply, assign(socket, view: "settings", mode: nil)}

  def handle_event("nav", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_expanded, &(not &1))}

  def handle_event("filter_vms", %{"q" => q}, socket), do: {:noreply, assign(socket, filter: q)}

  def handle_event("select_vm", %{"id" => id}, socket), do: {:noreply, open_vm(socket, id)}

  # ---- the side panel's tree: a VM's firmwares

  def handle_event("tree_toggle", %{"id" => id}, socket) do
    open = socket.assigns.tree_open
    {:noreply, assign(socket, tree_open: if(id in open, do: List.delete(open, id), else: [id | open]))}
  end

  # A firmware picked: it becomes the VM's program and the VM opens.
  def handle_event("pick_firmware", %{"id" => id, "file" => file}, socket) do
    {_, socket} = use_firmware(socket, id, file)
    {:noreply, socket}
  end

  # The play button: the same, then the VM starts with it.
  def handle_event("run_firmware", %{"id" => id, "file" => file}, socket) do
    case use_firmware(socket, id, file) do
      {:ok, socket} -> handle_event("start_vm", %{"id" => id}, socket)
      {:error, socket} -> {:noreply, socket}
    end
  end
  def handle_event("activate_tab", %{"id" => id}, socket), do: {:noreply, open_vm(socket, id)}

  def handle_event("close_tab", %{"id" => id}, socket) do
    tabs = socket.assigns.tabs
    i = Enum.find_index(tabs, &(&1 == id)) || 0
    rest = List.delete(tabs, id)
    socket = assign(socket, tabs: rest, tab_views: Map.delete(socket.assigns.tab_views, id))

    socket =
      if socket.assigns.selected == id do
        case Enum.at(rest, max(i - 1, 0)) do
          nil -> assign(socket, selected: nil)
          next -> open_vm(socket, next)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("vm_view", %{"view" => view}, socket) do
    {:noreply, socket |> assign(vm_view: view) |> remember_tab_view() |> prepare_view()}
  end

  def handle_event("show_section", %{"section" => section}, socket) do
    case SettingsNav.section(section) do
      nil -> {:noreply, socket}
      s -> {:noreply, assign(socket, settings_section: s.key)}
    end
  end

  # ------------------------------------------------------------- VM form

  def handle_event("new_vm", _params, socket), do: {:noreply, new_vm(socket, %{})}

  def handle_event("new_vm_from_iso", %{"path" => path}, socket),
    do: {:noreply, new_vm(socket, iso_params(path))}

  def handle_event("new_vm_from_image", %{"path" => path}, socket),
    do: {:noreply, new_vm(socket, image_params(path))}

  # the New VM's board shortcuts: architecture and board at once
  def handle_event("vm_preset", %{"machine" => machine}, socket) do
    {arch, machine} =
      case QemuAdmin.Board.for_machine(machine) do
        nil when machine == "renode" -> {"renode", Vm.default_machine("renode")}
        nil -> {"x86_64", "q35"}
        board -> {board.arch, board.machine}
      end

    params =
      socket.assigns.params
      |> merge_params(%{"arch" => arch, "machine" => machine})
      |> Map.put("machine", machine)

    {:noreply, assign(socket, params: params)}
  end

  def handle_event("validate_vm", %{"vm" => p}, socket) do
    params = merge_params(socket.assigns.params, p)
    {:noreply, assign(socket, params: params, errors: form_errors(socket, params))}
  end

  def handle_event("save_vm", %{"vm" => p}, socket) do
    params = merge_params(socket.assigns.params, p)
    socket = assign(socket, params: params, submitted: true)

    case socket.assigns.mode do
      :new ->
        case VmStore.create(params, socket.assigns.settings) do
          {:ok, vm} ->
            {:noreply,
             socket
             |> assign(mode: nil)
             |> load_vms()
             |> open_vm(vm.id, "overview")
             |> put_flash(:info, "VM \"#{vm.name}\" criada")
             |> after_create(vm, params)}

          {:error, errors} ->
            {:noreply, assign(socket, errors: Map.new(errors))}
        end

      _edit ->
        with {vm, _rt} <- current(socket),
             {:ok, vm} <- Vm.cast(vm, params) do
          VmStore.save(vm)

          {:noreply,
           socket
           |> load_vms()
           |> assign(errors: %{})
           |> put_flash(:info, "Configuração salva")}
        else
          {:error, errors} -> {:noreply, assign(socket, errors: Map.new(errors))}
          nil -> {:noreply, socket}
        end
    end
  end

  def handle_event("cancel_form", _params, socket) do
    case socket.assigns.mode do
      :new -> {:noreply, assign(socket, mode: nil)}
      _ -> {:noreply, socket |> assign(vm_view: "overview") |> prepare_view()}
    end
  end

  def handle_event("add_disk_row", _params, socket) do
    disks = Map.get(socket.assigns.params, "disks", %{})
    next = disks |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)
    row = %{"path" => "", "format" => "qcow2", "interface" => "virtio"}
    params = Map.put(socket.assigns.params, "disks", Map.put(disks, to_string(next + 1), row))
    {:noreply, assign(socket, params: params)}
  end

  def handle_event("remove_disk_row", %{"index" => i}, socket) do
    disks =
      socket.assigns.params
      |> Map.get("disks", %{})
      |> Map.delete(i)
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
      |> Enum.with_index()
      |> Map.new(fn {{_, d}, n} -> {to_string(n), d} end)

    {:noreply, assign(socket, params: Map.put(socket.assigns.params, "disks", disks))}
  end

  # ---------------------------------------------------------------- power

  def handle_event("start_vm", %{"id" => id}, socket) do
    with true <-
           not socket.assigns.sd_import.busy ||
             {:error, "Espere a importação do cartão SD terminar"},
         {:ok, vm} <- VmStore.get(id),
         {:ok, _pid} <- VmSupervisor.start_vm(vm) do
      socket = load_vms(socket)

      socket =
        if socket.assigns.selected == id and (vm.display == "vnc" or Vm.mcu?(vm)),
          do: socket |> assign(vm_view: "console") |> prepare_view(),
          else: socket

      {:noreply, socket}
    else
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "VM não encontrada")}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("powerdown_vm", %{"id" => id}, socket),
    do: {:noreply, qmp_result(socket, VmServer.powerdown(id))}

  def handle_event("reset_vm", %{"id" => id}, socket),
    do: {:noreply, qmp_result(socket, VmServer.reset(id))}

  def handle_event("pause_vm", %{"id" => id}, socket),
    do: {:noreply, qmp_result(socket, VmServer.pause(id))}

  def handle_event("resume_vm", %{"id" => id}, socket),
    do: {:noreply, qmp_result(socket, VmServer.resume(id))}

  # Force off: QMP `quit`, or the process killed when QMP does not answer.
  def handle_event("quit_vm", %{"id" => id}, socket) do
    case VmServer.quit(id) do
      {:ok, _} -> :ok
      _ -> VmServer.kill(id)
    end

    {:noreply, socket}
  end

  def handle_event("clone_vm", %{"id" => id}, socket) do
    with {:ok, vm} <- VmStore.get(id),
         false <- VmSupervisor.running?(id),
         {:ok, copy} <- VmStore.clone(vm, vm.name <> " (cópia)") do
      {:noreply,
       socket |> load_vms() |> open_vm(copy.id, "config") |> put_flash(:info, "VM clonada")}
    else
      true -> {:noreply, put_flash(socket, :error, "Desligue a VM antes de clonar")}
      _ -> {:noreply, put_flash(socket, :error, "Não foi possível clonar")}
    end
  end

  def handle_event("delete_vm", %{"id" => id}, socket) do
    if VmSupervisor.running?(id) do
      {:noreply, put_flash(socket, :error, "Desligue a VM antes de excluir")}
    else
      VmStore.delete(id)

      {:noreply,
       socket
       |> assign(tabs: List.delete(socket.assigns.tabs, id), selected: nil)
       |> load_vms()
       |> put_flash(:info, "VM excluída")}
    end
  end

  # ------------------------------------------------------------------- CD

  def handle_event("eject_cdrom", _params, socket) do
    case current(socket) do
      {vm, rt} ->
        if running?(rt), do: VmServer.eject(vm.id)
        VmStore.save(%{vm | cdrom: ""})
        {:noreply, socket |> load_vms() |> prepare_view()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("insert_iso", %{"id" => id, "path" => path}, socket) do
    {:noreply, socket |> insert_cdrom(id, path) |> load_images()}
  end

  # --------------------------------------------------------------- picker

  def handle_event("picker_open", %{"target" => target} = p, socket) do
    exts = p |> Map.get("exts", "") |> String.split(",", trim: true)
    picker = %{target: target, exts: exts, dirs?: target == "workspace"}
    {:noreply, picker_cd(socket, picker, picker_start(socket, target))}
  end

  def handle_event("picker_mkdir", %{"name" => name}, socket) do
    picker = socket.assigns.picker
    name = String.trim(name)

    cond do
      is_nil(picker) or name == "" ->
        {:noreply, socket}

      name =~ ~r{[\\/:*?"<>|]} ->
        {:noreply, put_flash(socket, :error, "nome de pasta inválido")}

      true ->
        dir = Path.join(picker.dir, name)

        case File.mkdir_p(dir) do
          :ok -> {:noreply, picker_cd(socket, picker, dir)}
          {:error, r} -> {:noreply, put_flash(socket, :error, "#{dir}: #{:file.format_error(r)}")}
        end
    end
  end

  def handle_event("picker_cd", %{"dir" => dir}, socket),
    do: {:noreply, picker_cd(socket, socket.assigns.picker, dir)}

  def handle_event("picker_cd", _params, socket),
    do: {:noreply, picker_cd(socket, socket.assigns.picker, "")}

  def handle_event("picker_go", %{"path" => path}, socket) do
    path = String.trim(path)

    if File.regular?(path) and not socket.assigns.picker[:dirs?],
      do: {:noreply, pick(socket, path)},
      else: {:noreply, picker_cd(socket, socket.assigns.picker, path)}
  end

  def handle_event("picker_pick", %{"path" => path}, socket), do: {:noreply, pick(socket, path)}
  def handle_event("picker_close", _params, socket), do: {:noreply, assign(socket, picker: nil)}

  # ---------------------------------------------------------------- disks

  def handle_event("refresh_disks", _params, socket),
    do: {:noreply, load_disk_info(socket, all_disks(socket))}

  def handle_event("create_disk", %{"vm" => id, "size" => size} = p, socket) do
    format = Map.get(p, "format", "qcow2")
    interface = Map.get(p, "interface", "virtio")

    with {:ok, vm} <- VmStore.get(id),
         name = next_disk_name(vm, format),
         {:ok, _} <- Img.create(Path.join(Vm.dir(vm), name), format, String.trim(size)) do
      disk = %{"path" => name, "format" => format, "interface" => interface}
      VmStore.save(%{vm | disks: vm.disks ++ [disk]})
      socket = load_vms(socket)

      {:noreply,
       socket
       |> load_disk_info(all_disks(socket))
       |> put_flash(:info, "Disco #{name} criado em #{vm.name}")}
    else
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "VM não encontrada")}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("resize_disk", %{"path" => path, "size" => size}, socket) do
    case Img.resize(path, String.trim(size)) do
      {:ok, _} ->
        {:noreply,
         socket |> load_disk_info(all_disks(socket)) |> put_flash(:info, "Disco redimensionado")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("refresh_images", _params, socket), do: {:noreply, load_images(socket)}

  def handle_event("image_download", %{"id" => id}, socket) do
    case Images.download(id) do
      :ok -> {:noreply, assign(socket, image_download: Images.state())}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # ------------------------------------------------------------ workspace

  def handle_event("open_workspace", %{"path" => path}, socket),
    do: {:noreply, open_workspace(socket, path)}

  def handle_event("reveal_workspace", _params, socket) do
    case Workspace.reveal() do
      :ok -> {:noreply, socket}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # Folded, the history is not in the page (a stream only keeps what it was sent
  # while it was on screen): opening it again loads it from the VM.
  def handle_event("cmds_toggle", _params, socket) do
    socket = update(socket, :cmds_open, &(not &1))

    case current(socket) do
      {vm, _rt} when socket.assigns.cmds_open -> {:noreply, load_cmds(socket, vm)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cmds_clear", _params, socket) do
    case current(socket) do
      {vm, _rt} ->
        VmServer.clear_commands(vm.id)
        {:noreply, load_cmds(socket, vm)}

      nil ->
        {:noreply, socket}
    end
  end

  # The launch line, edited on the Comandos page: `lp` is nil or
  # `%{id:, text:, error:}` (the VM, the text in the editor); saving keeps it in the
  # VM (`command`), empty restores the one the app builds.
  def handle_event("lp_edit", %{"id" => id}, socket) do
    case find_vm(socket.assigns.vms, id) do
      {vm, _rt} ->
        text = if vm.command in [nil, ""], do: Args.template(vm), else: vm.command
        {:noreply, assign(socket, lp: %{id: vm.id, text: text, error: nil})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("lp_change", %{"text" => text}, %{assigns: %{lp: lp}} = socket) when is_map(lp),
    do: {:noreply, assign(socket, lp: %{lp | text: text})}

  def handle_event("lp_change", _params, socket), do: {:noreply, socket}

  def handle_event("lp_cancel", _params, socket), do: {:noreply, assign(socket, lp: nil)}

  def handle_event("lp_reset", _params, %{assigns: %{lp: %{id: id}}} = socket) do
    case find_vm(socket.assigns.vms, id) do
      {vm, _rt} ->
        VmStore.save(%{vm | command: ""})

        {:noreply,
         socket
         |> assign(lp: nil)
         |> load_vms()
         |> refresh_command()
         |> put_flash(:info, "Linha de partida padrão restaurada")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("lp_reset", _params, socket), do: {:noreply, socket}

  def handle_event("lp_save", %{"text" => text}, %{assigns: %{lp: %{id: id}}} = socket) do
    with {vm, _rt} <- find_vm(socket.assigns.vms, id) do
      text = text |> String.replace(~r/\s*\R\s*/, " ") |> String.trim()

      # what the app builds itself is not stored: it follows the VM's settings
      custom? = text != Args.template(vm)

      case if(custom?, do: Args.check_command(vm, text), else: :ok) do
        :ok ->
          VmStore.save(%{vm | command: if(custom?, do: text, else: "")})

          {:noreply,
           socket
           |> assign(lp: nil)
           |> load_vms()
           |> refresh_command()
           |> put_flash(
             :info,
             if(custom?, do: "Linha de partida salva: vale no próximo boot", else: "Linha igual à padrão")
           )}

        {:error, msg} ->
          {:noreply, assign(socket, lp: %{id: id, text: text, error: msg})}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("lp_save", _params, socket), do: {:noreply, socket}

  # What is typed in the Terminal. A saved command (its name, alone) runs its steps
  # (`Macro.run/2`); anything else is executed as typed (`TermTools.execute/2`): a
  # QEMU tool with the VM on or off, a monitor or QMP command with it running.
  # Both run apart from the page and write to the VM's history, which shows live.
  def handle_event("cmd_send", %{"cmd" => input}, socket) do
    with {vm, _rt} <- current(socket), input when input != "" <- String.trim(input) do
      key = fn kind -> {kind, vm.id, System.unique_integer([:positive])} end

      case Saved.find(input, vm.id) do
        {:ok, command} -> {:noreply, start_async(socket, key.(:macro), fn -> Macro.run(vm.id, command) end)}
        :error -> {:noreply, start_async(socket, key.(:exec), fn -> TermTools.execute(vm, input) end)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ---- the Catálogo page: QEMU's commands, searched, filtered and filled in

  def handle_event("cat_search", %{"q" => q}, socket) do
    {total, found} = Catalog.search(q, extra: saved_entries(socket))
    {:noreply, update(socket, :cat, &%{&1 | gq: q, gres: found, gtotal: total, gopen: true})}
  end

  def handle_event("cat_search_focus", _params, socket),
    do: {:noreply, update(socket, :cat, &%{&1 | gopen: true})}

  def handle_event("cat_search_close", _params, socket),
    do: {:noreply, update(socket, :cat, &%{&1 | gopen: false})}

  # Enter in the search box: the best result.
  def handle_event("cat_search_enter", _params, socket) do
    case socket.assigns.cat.gres do
      [e | _] -> {:noreply, cat_pick(socket, e)}
      [] -> {:noreply, socket}
    end
  end

  def handle_event("cat_pick", %{"id" => id}, socket) do
    case Catalog.get(id, saved_entries(socket)) do
      nil -> {:noreply, socket}
      e -> {:noreply, cat_pick(socket, e)}
    end
  end

  def handle_event("cat_filter", %{"q" => q}, socket),
    do: {:noreply, update(socket, :cat, &%{&1 | q: q})}

  def handle_event("cat_kind", %{"kind" => kind}, socket) when kind in ~w(all saved hmp qmp event tool launch),
    do: {:noreply, update(socket, :cat, &%{&1 | kind: kind})}

  def handle_event("cat_select", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :cat, fn cat ->
       if cat.sel == id, do: %{cat | sel: nil, vals: %{}}, else: %{cat | sel: id, vals: %{}}
     end)}
  end

  def handle_event("cat_vals", params, socket) do
    vals = for {k, v} <- Map.get(params, "v", %{}), is_binary(v), into: %{}, do: {k, v}
    {:noreply, update(socket, :cat, &%{&1 | vals: vals, to: Map.get(params, "to", &1.to)})}
  end

  # A saved command, run on the selected VM like one typed in its Terminal.
  def handle_event("cat_run", %{"name" => name}, socket),
    do: handle_event("cmd_send", %{"cmd" => name}, socket)

  # Sends the filled-in line to the selected VM's Terminal: it runs apart from the
  # page and shows in the history like anything typed there.
  def handle_event("cat_send", params, socket) do
    socket = apply_cat_params(socket, params)

    with {vm, _rt} <- current(socket),
         line when is_binary(line) <- cat_line(socket) do
      key = {:exec, vm.id, System.unique_integer([:positive])}

      {:noreply,
       socket
       |> start_async(key, fn -> TermTools.execute(vm, line, "catálogo") end)
       |> put_flash(:info, "Enviado ao Terminal de #{vm.name}: #{line}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Selecione uma VM para receber o comando")}
    end
  end

  # The line as a step: of the saved command chosen, or the start of a new one.
  def handle_event("cat_step", params, socket) do
    socket = apply_cat_params(socket, params)

    case cat_line(socket) do
      nil ->
        {:noreply, socket}

      line ->
        case socket.assigns.cat.to do
          "" ->
            form = Map.put(blank_saved(), "steps", line)

            {:noreply,
             socket
             |> assign(view: "commands", mode: nil, cp: %{editing: form, error: nil})
             |> load_commands()}

          name ->
            {:noreply, cat_add_step(socket, name, line)}
        end
    end
  end

  # ---- the Comandos page: every saved command, to create, edit and delete

  def handle_event("cp_new", _params, socket),
    do: {:noreply, update(socket, :cp, &%{&1 | editing: blank_saved(), error: nil})}

  def handle_event("cp_edit", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.cp_commands, &(&1["name"] == name)) do
      nil ->
        {:noreply, socket}

      c ->
        form = %{
          "original" => c["name"],
          "name" => c["name"],
          "description" => c["description"],
          "vm" => c["vm"] || "",
          "steps" => Enum.join(c["steps"], "\n"),
          "continue_on_error" => c["continue_on_error"]
        }

        {:noreply, update(socket, :cp, &%{&1 | editing: form, error: nil})}
    end
  end

  def handle_event("cp_change", %{"saved" => params}, %{assigns: %{cp: %{editing: form}}} = socket)
      when is_map(form) do
    form =
      form
      |> Map.merge(Map.take(params, ~w(name description vm steps)))
      |> Map.put("continue_on_error", params["continue_on_error"] in ["true", "on"])

    {:noreply, update(socket, :cp, &%{&1 | editing: form})}
  end

  def handle_event("cp_change", _params, socket), do: {:noreply, socket}

  def handle_event("cp_cancel", _params, socket),
    do: {:noreply, update(socket, :cp, &%{&1 | editing: nil, error: nil})}

  def handle_event("cp_save", %{"saved" => params}, %{assigns: %{cp: %{editing: form} = cp}} = socket)
      when is_map(form) do
    original =
      case form do
        %{"original" => o} when o not in [nil, ""] -> o
        _ -> nil
      end

    with {:ok, command} <- Saved.validate(params),
         :ok <- Saved.save(command, original) do
      {:noreply,
       socket
       |> assign(cp: %{cp | editing: nil, error: nil})
       |> update(:cat, &%{&1 | kind: "saved", q: "", sel: "saved:#{command["name"]}", vals: %{}})
       |> load_commands()
       |> put_flash(:info, "Comando salvo: #{command["name"]}")}
    else
      {:error, msg} ->
        form = Map.merge(form, Map.take(params, ~w(name description vm steps)))
        {:noreply, assign(socket, cp: %{cp | editing: form, error: msg})}
    end
  end

  def handle_event("cp_save", _params, socket), do: {:noreply, socket}

  def handle_event("cp_delete", %{"name" => name}, socket) do
    case Saved.delete(name) do
      :ok ->
        {:noreply,
         socket
         |> update(:cat, &%{&1 | sel: nil})
         |> load_commands()
         |> put_flash(:info, "Comando excluído: #{name}")}

      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("forget_workspace", %{"path" => path}, socket) do
    Workspace.forget(path)
    {:noreply, assign(socket, workspaces: Workspace.list())}
  end

  # ---------------------------------------------------------------- board

  # an input pin clicked: the level the outside world drives flips
  def handle_event("gpio_toggle", %{"gpio" => g}, socket) do
    with {vm, _rt} <- current(socket),
         {gpio, ""} <- Integer.parse(g),
         %{pins: pins} <- socket.assigns.gpio do
      level = if match?(%{level: 1}, pins[gpio]), do: 0, else: 1
      Gpio.set_input(vm.id, gpio, level)
    end

    {:noreply, socket}
  end

  def handle_event(event, _params, socket) when event in ["avr_erase", "cortexm_erase"] do
    with {vm, rt} <- current(socket),
         true <- stopped?(rt) || {:error, "Desligue a placa antes de apagar"} do
      if Vm.kind(vm) == :cortexm,
        do: CortexMFw.erase(Vm.dir(vm)),
        else: AvrFirmware.erase(Vm.dir(vm))

      VmStore.save(%{vm | firmware: "", app: ""})
      {:noreply, socket |> load_vms() |> put_flash(:info, "Programa apagado")}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("sd_user", params, socket),
    do: {:noreply, assign(socket, sd_user: Map.take(params, ~w(user password ssh)))}

  def handle_event("sd_append", %{"append" => append}, socket) do
    case current(socket) do
      {vm, _rt} ->
        VmStore.save(%{vm | append: String.trim(append)})
        {:noreply, socket |> load_vms() |> put_flash(:info, "Linha de comando salva")}

      nil ->
        {:noreply, socket}
    end
  end

  # ----------------------------------------------------------------- QEMU

  def handle_event("install_qemu", %{"kind" => "esp"}, socket) do
    InstallJob.start(:esp)
    {:noreply, assign(socket, install_esp: InstallJob.state(:esp))}
  end

  def handle_event("install_qemu", _params, socket) do
    InstallJob.start(:qemu)
    {:noreply, assign(socket, install: InstallJob.state(:qemu))}
  end

  def handle_event("refresh_qemu", _params, socket),
    do: {:noreply, assign(socket, qemu: Qemu.refresh())}

  # --------------------------------------------------------- ESP32 serial

  def handle_event("serial_init", %{"id" => id}, socket) do
    {data, total} = VmServer.serial_buffer(id)
    {:reply, %{data: Base.encode64(data), total: total}, socket}
  end

  def handle_event("serial_input", %{"id" => id, "data" => data}, socket) do
    VmServer.serial_write(id, data)
    {:noreply, socket}
  end

  # ---------------------------------------------------------- ESP32 flash

  def handle_event("atomvm_install", %{"tag" => tag, "flavor" => flavor}, socket) do
    case current(socket) do
      {vm, rt} ->
        if stopped?(rt) do
          flash = flash_path(vm)

          {:noreply,
           socket
           |> update(:atomvm, &%{&1 | busy: true, error: nil})
           |> start_async(:atomvm_install, fn ->
             with {:ok, image} <- AtomVM.fetch(vm.machine, tag, flavor),
                  :ok <- AtomVM.install(flash, vm.machine, image) do
               {:ok, vm.id, "AtomVM #{tag}#{if flavor == "elixir", do: " (Elixir)"}"}
             end
           end)}
        else
          {:noreply, put_flash(socket, :error, "Desligue o chip antes de gravar")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("flash_offset", %{"offset" => offset}, socket),
    do: {:noreply, assign(socket, flash_offset: offset)}

  def handle_event("flash_erase", _params, socket) do
    with {vm, rt} <- current(socket),
         true <- stopped?(rt) || {:error, "Desligue o chip antes de apagar a flash"},
         :ok <- EspFlash.erase(flash_path(vm)) do
      VmStore.save(%{vm | firmware: "", app: ""})
      {:noreply, socket |> load_vms() |> prepare_view() |> put_flash(:info, "Flash apagada")}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, socket}
    end
  end

  # ------------------------------------------------------------- settings

  # the workspace is opened (and checked) like from the switcher
  def handle_event("set_setting", %{"key" => "workspace"} = p, socket),
    do: {:noreply, open_workspace(socket, Map.get(p, "value", ""))}

  def handle_event("set_setting", %{"key" => key} = p, socket) do
    settings = Settings.put(%{key => Map.get(p, "value", "")})
    socket = assign(socket, settings: settings)

    socket =
      case key do
        "qemu_dir" -> assign(socket, qemu: Qemu.refresh())
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("reset_settings", %{"section" => section}, socket) do
    defaults =
      case SettingsNav.section(section) do
        nil -> %{}
        s -> s.key |> Settings.section() |> Map.new(&{&1.key, &1.default})
      end

    settings = Settings.put(defaults)
    {:noreply, socket |> assign(settings: settings, qemu: Qemu.refresh()) |> load_vms()}
  end

  # ---------------------------------------------------------------- close

  # The title bar's close (or Alt+F4, relayed by the shell).
  def handle_event("window_close", _params, socket) do
    names = running_names(socket)

    cond do
      names == [] -> {:noreply, push_event(socket, "qa:close-window", %{})}
      socket.assigns.settings.confirm_close -> {:noreply, assign(socket, close: :ask)}
      true -> {:noreply, shutdown_and_close(socket, socket.assigns.settings.stop_timeout)}
    end
  end

  def handle_event("close_confirm", %{"how" => "cancel"}, socket),
    do: {:noreply, assign(socket, close: nil)}

  def handle_event("close_confirm", %{"how" => "force"}, socket),
    do: {:noreply, shutdown_and_close(socket, 0)}

  def handle_event("close_confirm", %{"how" => "shutdown"}, socket),
    do: {:noreply, shutdown_and_close(socket, socket.assigns.settings.stop_timeout)}

  def handle_event("vnc_title", _params, socket), do: {:noreply, socket}

  @impl true
  # a Terminal line or a saved command finished: everything it printed is in the VM's
  # history already; the page reloads what it may have changed (a disk made, resized…)
  def handle_async({kind, _id, _n}, {:ok, _result}, socket) when kind in [:exec, :macro],
    do: {:noreply, prepare_view(socket)}

  def handle_async({kind, id, _n}, {:exit, reason}, socket) when kind in [:exec, :macro] do
    TermTools.log(id, "error", "o comando falhou: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async(:shutdown, _result, socket) do
    {:noreply, push_event(socket, "qa:close-window", %{})}
  end

  def handle_async(:atomvm_releases, {:ok, {:ok, releases}}, socket),
    do: {:noreply, update(socket, :atomvm, &%{&1 | releases: releases, error: nil})}

  def handle_async(:atomvm_releases, {:ok, {:error, msg}}, socket),
    do:
      {:noreply,
       update(socket, :atomvm, &%{&1 | error: "Não foi possível listar as versões: #{msg}"})}

  def handle_async(:atomvm_releases, {:exit, reason}, socket),
    do:
      {:noreply,
       update(
         socket,
         :atomvm,
         &%{&1 | error: "Não foi possível listar as versões: #{inspect(reason)}"}
       )}

  def handle_async(:atomvm_install, {:ok, {:ok, id, firmware}}, socket) do
    with {:ok, vm} <- VmStore.get(id), do: VmStore.save(%{vm | firmware: firmware, app: ""})

    {:noreply,
     socket
     |> update(:atomvm, &%{&1 | busy: false})
     |> load_vms()
     |> prepare_view()
     |> put_flash(:info, "#{firmware} gravado — grave o seu app (.avm) e ligue o chip")}
  end

  def handle_async(:atomvm_install, {:ok, {:error, msg}}, socket),
    do: {:noreply, update(socket, :atomvm, &%{&1 | busy: false, error: to_string(msg)})}

  def handle_async(:sd_import, {:ok, {:ok, id, src, boot}}, socket) do
    with {:ok, vm} <- VmStore.get(id) do
      VmStore.save(%{
        vm
        | disks: [%{"path" => boot.disk, "format" => "raw", "interface" => "sd"}],
          kernel: boot.kernel,
          dtb: boot.dtb,
          append: boot.append,
          firmware: Path.basename(src)
      })
    end

    {:noreply,
     socket
     |> assign(sd_import: %{busy: false, error: nil})
     |> load_vms()
     |> put_flash(:info, "#{Path.basename(src)} no cartão SD — pode ligar")}
  end

  def handle_async(:sd_import, {:ok, {:error, msg}}, socket),
    do: {:noreply, assign(socket, sd_import: %{busy: false, error: to_string(msg)})}

  def handle_async(:sd_import, {:exit, reason}, socket),
    do: {:noreply, assign(socket, sd_import: %{busy: false, error: inspect(reason)})}

  def handle_async(:atomvm_install, {:exit, reason}, socket),
    do: {:noreply, update(socket, :atomvm, &%{&1 | busy: false, error: inspect(reason)})}

  # --------------------------------------------------------------- PubSub

  @impl true
  def handle_info({:vm_status, id, _status}, socket) do
    socket = refresh_runtimes(socket)
    socket = if socket.assigns.selected == id, do: refresh_command(socket), else: socket
    {:noreply, socket}
  end

  def handle_info({:vm_screen, _id, _rev}, socket), do: {:noreply, refresh_runtimes(socket)}

  def handle_info({:vms_changed, _id}, socket), do: {:noreply, load_vms(socket)}

  def handle_info({:vm_log, id, line}, %{assigns: %{selected: id, vm_view: "log"}} = socket) do
    seq = socket.assigns.log_seq + 1

    {:noreply,
     socket
     |> assign(log_seq: seq)
     |> stream_insert(:log, %{id: seq, text: line}, limit: -@log_limit)}
  end

  def handle_info({:vm_log, _id, _line}, socket), do: {:noreply, socket}

  def handle_info({:vm_cmd, id, entry}, %{assigns: %{selected: id}} = socket) do
    # a line of a command goes in again as its row, which is updated where it is
    {groups, row} = Groups.add(socket.assigns.cmd_groups, entry)

    {:noreply,
     socket
     |> assign(cmd_groups: groups)
     |> stream_insert(:cmds, row, limit: -@cmd_limit)
     |> update(:cmd_history, &history_add(&1, entry))}
  end

  def handle_info({:vm_cmd, _id, _entry}, socket), do: {:noreply, socket}

  def handle_info(
        {:vm_serial, id, offset, data},
        %{assigns: %{selected: id, vm_view: view}} = socket
      )
      when view in ["console", "serial"],
      do:
        {:noreply,
         push_event(socket, "qa:serial", %{id: id, offset: offset, data: Base.encode64(data)})}

  def handle_info({:vm_serial, _id, _offset, _data}, socket), do: {:noreply, socket}

  def handle_info({:vm_gpio, id, snap}, %{assigns: %{selected: id}} = socket),
    do: {:noreply, assign(socket, gpio: snap)}

  def handle_info({:vm_gpio, _id, _snap}, socket), do: {:noreply, socket}

  def handle_info({:image_download, job}, socket) do
    socket = assign(socket, image_download: job)
    {:noreply, if(job.phase == :done, do: load_images(socket), else: socket)}
  end

  def handle_info({:qemu_install, kind, job}, socket) do
    socket = assign(socket, if(kind == :esp, do: :install_esp, else: :install), job)
    socket = if job.phase == :done, do: assign(socket, qemu: Qemu.info()), else: socket
    {:noreply, socket}
  end

  def handle_info({:settings, settings}, socket),
    do: {:noreply, assign(socket, settings: settings, workspaces: Workspace.list())}

  # uptime (and an ESP32's last serial lines) on the overview
  def handle_info(:tick, socket) do
    if socket.assigns.selected && socket.assigns.vm_view == "overview",
      do: {:noreply, socket |> refresh_runtimes() |> load_serial_tail()},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------- helpers

  defp load_vms(socket) do
    vms = for vm <- VmStore.list(), do: {vm, VmSupervisor.runtime(vm.id)}
    ids = MapSet.new(vms, fn {vm, _} -> vm.id end)
    selected = if socket.assigns.selected in ids, do: socket.assigns.selected
    tabs = Enum.filter(socket.assigns.tabs, &(&1 in ids))
    assign(socket, vms: vms, selected: selected, tabs: tabs)
  end

  defp refresh_runtimes(socket) do
    assign(socket,
      vms: Enum.map(socket.assigns.vms, fn {vm, _} -> {vm, VmSupervisor.runtime(vm.id)} end)
    )
  end

  defp current(socket), do: find_vm(socket.assigns.vms, socket.assigns.selected)

  defp find_vm(_vms, nil), do: nil
  defp find_vm(vms, id), do: Enum.find(vms, fn {vm, _} -> vm.id == id end)

  defp running_names(socket) do
    for {vm, rt} <- socket.assigns.vms, running?(rt), do: vm.name
  end

  defp open_vm(socket, id, view \\ nil) do
    if found = find_vm(socket.assigns.vms, id) do
      {vm, _rt} = found

      tabs =
        if id in socket.assigns.tabs, do: socket.assigns.tabs, else: socket.assigns.tabs ++ [id]

      # each tab goes back to what it was showing
      view = view || socket.assigns.tab_views[id] || "overview"
      # "flash" is an ESP32's only
      view = if Enum.any?(vm_views(vm), &(elem(&1, 0) == view)), do: view, else: "overview"

      socket
      |> assign(view: "vms", mode: nil, selected: id, tabs: tabs, vm_view: view)
      |> remember_tab_view()
      |> prepare_view()
    else
      socket
    end
  end

  defp remember_tab_view(%{assigns: %{selected: id, vm_view: view}} = socket) when is_binary(id),
    do: update(socket, :tab_views, &Map.put(&1, id, view))

  defp remember_tab_view(socket), do: socket

  # The tabs as they were left (`QemuAdmin.Session`, session.json in the workspace):
  # the VMs that are gone are dropped, a tab with no view goes to the overview.
  defp restore_session(socket) do
    session = Session.load()
    ids = for {vm, _} <- socket.assigns.vms, do: vm.id
    tabs = Enum.filter(session["tabs"], &(&1 in ids))
    views = Map.take(session["views"], tabs)

    socket =
      assign(socket,
        tabs: tabs,
        tab_views: views,
        cmds_open: session["terminal_open"],
        selected: nil,
        mode: nil
      )

    cond do
      session["view"] == "vms" and session["selected"] in tabs ->
        open_vm(socket, session["selected"])

      session["view"] in ~w(disks images qemu commands settings) ->
        {:noreply, socket} = handle_event("nav", %{"view" => session["view"]}, socket)
        socket

      true ->
        assign(socket, view: "vms")
    end
  end

  # after each render: write the session when it is not what the file has
  defp save_session(socket) do
    a = socket.assigns

    session = %{
      "view" => a.view,
      "selected" => a.selected,
      "tabs" => a.tabs,
      "views" => a.tab_views,
      "terminal_open" => a.cmds_open
    }

    if connected?(socket) and session != socket.private[:session_saved] do
      _ = Session.save(session)
      Phoenix.LiveView.put_private(socket, :session_saved, session)
    else
      socket
    end
  end

  # What a VM view needs loaded when it opens.
  defp prepare_view(socket) do
    case current(socket) do
      nil ->
        socket

      {vm, _rt} ->
        socket = socket |> load_cmds(vm) |> load_saved()

        case socket.assigns.vm_view do
          "overview" ->
            socket
            |> load_disk_info(Enum.map(vm.disks, &Vm.resolve(vm, &1["path"])))
            |> refresh_command()
            |> load_serial_tail()

          "flash" ->
            socket |> load_flash(vm) |> load_atomvm_releases(vm)

          "io" ->
            assign(socket, gpio: Gpio.snapshot(vm.id))

          "config" ->
            assign(socket, params: vm_params(vm), errors: %{}, submitted: false)

          "log" ->
            lines = VmServer.log(vm.id)

            items =
              lines
              |> Enum.take(-@log_limit)
              |> Enum.with_index(1)
              |> Enum.map(fn {l, i} -> %{id: i, text: l} end)

            socket |> assign(log_seq: length(items)) |> stream(:log, items, reset: true)

          _ ->
            socket
        end
    end
  end

  # The saved commands (terminal.json) the selected VM has: what the Terminal suggests.
  defp load_saved(socket) do
    case current(socket) do
      {vm, _rt} -> assign(socket, saved: Saved.list(vm.id))
      nil -> socket
    end
  end

  # What each VM starts with: the line it was edited to, else the one the app builds.
  defp launch_lines(vms) do
    Map.new(vms, fn {vm, _rt} ->
      {vm.id, if(vm.command in [nil, ""], do: Args.template(vm), else: vm.command)}
    end)
  end

  defp blank_cat do
    %{q: "", kind: "all", sel: nil, vals: %{}, to: "", gq: "", gres: [], gtotal: 0, gopen: false}
  end

  defp apply_cat_params(socket, params) do
    case params do
      %{"v" => _} -> elem(handle_event("cat_vals", params, socket), 1)
      %{"to" => _} -> elem(handle_event("cat_vals", params, socket), 1)
      _ -> socket
    end
  end

  # A result was chosen: the table narrows to it and its editor opens.
  defp cat_pick(socket, e) do
    update(socket, :cat, &%{&1 | kind: "all", q: e.name, sel: e.id, vals: %{}, gopen: false})
  end

  defp cat_line(%{assigns: %{cat: %{sel: sel, vals: vals}}}) when is_binary(sel) do
    with %{} = e <- Catalog.get(sel), do: Catalog.line(e, vals)
  end

  defp cat_line(_socket), do: nil

  defp cat_add_step(socket, name, line) do
    with {:ok, commands} <- Saved.load(),
         %{} = c <- Enum.find(commands, &(&1["name"] == name)),
         {:ok, command} <- Saved.validate(%{c | "steps" => c["steps"] ++ [line]}),
         :ok <- Saved.save(command, name) do
      socket |> load_commands() |> put_flash(:info, "Passo adicionado a #{name}: #{line}")
    else
      {:error, msg} -> put_flash(socket, :error, msg)
      _ -> put_flash(socket, :error, "Comando salvo não encontrado: #{name}")
    end
  end

  # Makes `file` the program of VM `id` (stopped) and opens it: `{:ok | :error, socket}`.
  defp use_firmware(socket, id, file) do
    with {vm, rt} <- find_vm(socket.assigns.vms, id),
         true <- stopped?(rt) || {:error, "Desligue a VM antes de trocar o firmware"},
         true <- Enum.any?(QemuAdmin.Firmwares.list(vm), &(&1.file == file)) || {:error, "firmware não encontrado: #{file}"},
         {:ok, vm} <- VmStore.save(%{vm | program: file}) do
      socket = socket |> load_vms() |> open_vm(vm.id)
      {:ok, put_flash(socket, :info, "#{vm.name}: firmware #{file}")}
    else
      {:error, msg} -> {:error, put_flash(socket, :error, msg)}
      _ -> {:error, put_flash(socket, :error, "VM não encontrada")}
    end
  end

  defp saved_entries(socket), do: Catalog.saved_entries(socket.assigns.cp_commands)

  defp vm_name(socket_assigns) do
    case find_vm(socket_assigns.vms, socket_assigns.selected) do
      {vm, _rt} -> vm.name
      nil -> nil
    end
  end

  # Every saved command (terminal.json), for the Comandos page.
  defp load_commands(socket) do
    case Saved.load() do
      {:ok, commands} ->
        assign(socket, cp_commands: Enum.sort_by(commands, &String.downcase(&1["name"])), cp_file_error: nil)

      {:error, msg} ->
        assign(socket, cp_commands: [], cp_file_error: msg)
    end
  end

  defp blank_saved do
    %{
      "original" => "",
      "name" => "",
      "description" => "",
      "vm" => "",
      "steps" => "",
      "continue_on_error" => false
    }
  end

  # The terminal's history: this VM's, from the running server or the file.
  defp load_cmds(socket, vm) do
    entries = VmServer.commands(vm.id)
    {groups, rows} = Groups.build(entries)

    socket
    |> assign(cmd_history: Enum.reduce(entries, [], &history_add(&2, &1)), cmd_groups: groups)
    |> stream(:cmds, rows, reset: true)
  end

  # What the prompt's arrow keys recall: what was typed (a command's own line, not
  # its wire message), without repeats in a row.
  defp history_add(history, %{dir: "cmd", src: "digitado", text: text}), do: remember(history, text)

  defp history_add(history, %{dir: dir, text: text} = entry)
       when dir in ["hmp", "sent", "tool", "typed"] and not is_map_key(entry, :x),
       do: remember(history, text)

  defp history_add(history, _entry), do: history

  defp remember(history, text) do
    if List.last(history) == text, do: history, else: Enum.take(history ++ [text], -100)
  end

  # The command line shown on the overview: the real one while running,
  # otherwise what the next start would run (ports shown as placeholders).
  defp refresh_command(socket) do
    case current(socket) do
      {vm, rt} ->
        command =
          case running?(rt) && VmServer.command_line(vm.id) do
            cmd when is_binary(cmd) ->
              cmd

            _ ->
              exe =
                case Qemu.system_exe(vm.arch) do
                  {:ok, exe} -> exe
                  _ -> "qemu-system-#{vm.arch}"
                end

              Args.command_line(
                exe,
                Args.build_run(vm, %{qmp: 4444, vnc: 5900, ws: 5700, serial: 5555, gdb: 4445})
              )
          end

        assign(socket, command: command)

      nil ->
        socket
    end
  end

  defp flash_path(vm),
    do: Vm.resolve(vm, (List.first(vm.disks) || %{"path" => "flash.bin"})["path"])

  defp load_flash(socket, vm) do
    path = flash_path(vm)

    flash =
      case EspFlash.size(path) do
        {:ok, size} ->
          %{path: path, size: size, partitions: EspFlash.partitions(path), error: nil}

        {:error, msg} ->
          %{path: path, size: nil, partitions: [], error: msg}
      end

    assign(socket, esp_flash: flash)
  end

  # The AtomVM versions, once per page — GitHub's API is rate limited.
  defp load_atomvm_releases(socket, vm) do
    if socket.assigns.atomvm.releases do
      socket
    else
      chip = vm.machine
      start_async(socket, :atomvm_releases, fn -> AtomVM.releases(chip) end)
    end
  end

  # An ESP32's last lines of serial output, for its overview.
  defp load_serial_tail(socket) do
    case current(socket) do
      {vm, _rt} ->
        if Vm.serial?(vm) do
          {data, _} = VmServer.serial_buffer(vm.id)
          tail = binary_part(data, max(byte_size(data) - 4096, 0), min(byte_size(data), 4096))
          assign(socket, serial_tail: serial_lines(tail))
        else
          socket
        end

      nil ->
        socket
    end
  end

  # Printable text: ANSI colours (ESP-IDF's log levels) and invalid UTF-8 out.
  defp serial_lines(bytes) do
    bytes
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> then(&if(String.valid?(&1), do: &1, else: :unicode.characters_to_binary(&1, :latin1)))
    |> String.split(~r/\r?\n/)
    |> Enum.take(-14)
  end

  defp load_disk_info(socket, paths) do
    info =
      if Qemu.available?() do
        paths
        |> Enum.uniq()
        |> Task.async_stream(&{&1, Img.info(&1)}, timeout: 15_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, pair} -> [pair]
          _ -> []
        end)
        |> Map.new()
      else
        Map.new(paths, &{&1, {:error, "QEMU não encontrado"}})
      end

    assign(socket, disk_info: info)
  end

  defp all_disks(socket) do
    for {vm, _} <- socket.assigns.vms, d <- vm.disks, do: Vm.resolve(vm, d["path"])
  end

  defp next_disk_name(vm, format) do
    ext = if format == "raw", do: "img", else: format

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&"disk#{&1}.#{ext}")
    |> Enum.find(&(not File.exists?(Path.join(Vm.dir(vm), &1))))
  end

  defp load_images(socket), do: assign(socket, images: Images.list())

  defp open_workspace(socket, path) do
    case Workspace.open(path) do
      {:ok, dir} ->
        socket
        |> assign(workspaces: Workspace.list())
        |> load_vms()
        |> restore_session()
        |> load_images()
        |> put_flash(:info, "Workspace: #{Workspace.name(dir)}")

      {:error, msg} ->
        put_flash(socket, :error, msg)
    end
  end

  # What a new VM still needs once it exists: an Arduino's program, a
  # Raspberry Pi's SD card (imported in the background: it is a big copy).
  defp after_create(socket, vm, params) do
    case {Vm.kind(vm), params} do
      {kind, %{"firmware_src" => src}} when kind in [:avr, :cortexm] and src != "" ->
        firmware_write(socket, vm, src)

      {:raspi, %{"sd_image" => src}} when src != "" ->
        user = %{
          "user" => Map.get(params, "sd_user", "pi"),
          "password" => Map.get(params, "sd_password", "raspberry"),
          "ssh" => Map.get(params, "sd_ssh", "true")
        }

        sd_import(socket, vm, src, user)

      _ ->
        socket
    end
  end

  defp firmware_write(socket, vm, src) do
    result =
      if Vm.kind(vm) == :cortexm,
        do: CortexMFw.install(Vm.dir(vm), src),
        else: AvrFirmware.install(Vm.dir(vm), src, vm.machine)

    case result do
      :ok ->
        VmStore.save(%{vm | firmware: Path.basename(src), app: src})
        socket |> load_vms() |> put_flash(:info, "#{Path.basename(src)} gravado na flash")

      {:error, msg} ->
        put_flash(socket, :error, msg)
    end
  end

  defp sd_import(socket, vm, src, user \\ nil) do
    board = Vm.board(vm)
    dir = Vm.dir(vm)
    user = user || socket.assigns.sd_user
    opts = [user: user["user"], password: user["password"], ssh: user["ssh"] == "true"]

    socket
    |> assign(sd_import: %{busy: true, error: nil})
    |> start_async(:sd_import, fn ->
      with {:ok, boot} <- RaspiImage.import(src, dir, board, opts), do: {:ok, vm.id, src, boot}
    end)
  end

  defp new_vm(socket, extra) do
    params =
      socket.assigns.settings
      |> Vm.new()
      |> vm_params()
      |> Map.merge(%{"disk_size" => "32G", "disk_format" => "qcow2", "flash_size" => "4"})
      |> Map.merge(extra)

    assign(socket,
      view: "vms",
      selected: nil,
      mode: :new,
      params: params,
      errors: %{},
      submitted: false,
      picker: nil
    )
  end

  # A new VM from a file of the library, of the kind the file is for.
  defp image_params(path) do
    name = path |> Path.basename() |> Path.rootname() |> Path.rootname() |> String.slice(0, 40)

    case Images.kind(path) do
      {:iso, _} ->
        iso_params(path)

      {:disk, _} ->
        format = Path.extname(path) |> String.trim_leading(".") |> String.downcase()

        %{
          "name" => name,
          "disk_size" => "",
          "disks" => %{"0" => %{"path" => path, "format" => format, "interface" => "virtio"}}
        }

      {:sd, _} ->
        machine = if path =~ ~r/armhf/i, do: "raspi2b", else: "raspi3b"
        board_params(machine, %{"name" => name, "sd_image" => path})

      {:avr, _} ->
        board_params("arduino-uno", %{"name" => name, "firmware_src" => path})

      _ ->
        board_params("esp32", %{"name" => name})
    end
  end

  defp board_params(machine, extra) do
    board = QemuAdmin.Board.for_machine(machine)
    d = Vm.kind_defaults(board.kind, machine)

    Map.merge(
      %{
        "arch" => board.arch,
        "machine" => machine,
        "memory" => to_string(d.memory),
        "cpus" => to_string(d.cpus),
        "net_model" => d.net_model
      },
      extra
    )
  end

  # A new VM from an ISO: its name, boot from CD, and the guesses that save
  # a first-boot failure — UEFI and localtime for Windows, aarch64 for an
  # ARM image.
  defp iso_params(path) do
    base = path |> Path.basename() |> Path.rootname()
    windows? = base =~ ~r/win/i
    arm? = base =~ ~r/arm64|aarch64/i

    name =
      base
      |> String.replace(~r/[_\.]+/, " ")
      |> String.slice(0, 40)

    %{"name" => name, "cdrom" => path, "boot" => "cdrom"}
    |> Map.merge(
      if windows?,
        do: %{"uefi" => "true", "localtime" => "true", "memory" => "4096", "disk_size" => "64G"},
        else: %{}
    )
    |> Map.merge(
      if arm?, do: %{"arch" => "aarch64", "machine" => "virt", "uefi" => "true"}, else: %{}
    )
  end

  # The form's params from a VM (string keys, as the form sends them).
  defp vm_params(%Vm{} = vm) do
    %{
      "name" => vm.name,
      "arch" => vm.arch,
      "machine" => vm.machine,
      "cpu" => vm.cpu,
      "cpus" => to_string(vm.cpus),
      "memory" => to_string(vm.memory),
      "accel" => vm.accel,
      "display" => vm.display,
      "vga" => vm.vga,
      "uefi" => to_string(vm.uefi),
      "localtime" => to_string(vm.localtime),
      "boot" => vm.boot,
      "cdrom" => vm.cdrom || "",
      "disks" => vm.disks |> Enum.with_index() |> Map.new(fn {d, i} -> {to_string(i), d} end),
      "net_mode" => vm.net_mode,
      "net_model" => vm.net_model,
      "forwards" => Enum.join(vm.forwards, "\n"),
      "usb_tablet" => to_string(vm.usb_tablet),
      "extra_args" => vm.extra_args || "",
      "notes" => vm.notes || ""
    }
  end

  # What the form sent over what the page kept. A new architecture takes its
  # own default board (and UEFI, for aarch64); going to or from an ESP32 also
  # its memory and NIC (MiB of PSRAM are not MiB of RAM).
  defp merge_params(old, new) do
    merged = Map.merge(old, new)

    merged =
      if not Map.has_key?(new, "disks") and Map.has_key?(new, "name"),
        do: Map.put(merged, "disks", %{}),
        else: merged

    merged =
      if new["arch"] && new["arch"] != old["arch"] do
        merged
        |> Map.put("machine", Vm.default_machine(new["arch"]))
        |> then(&if(new["arch"] == "aarch64", do: Map.put(&1, "uefi", "true"), else: &1))
      else
        merged
      end

    # another board has other UARTs
    merged = if merged["machine"] != old["machine"], do: Map.put(merged, "uart", ""), else: merged

    old_kind = Vm.kind(old["arch"] || "", old["machine"] || "")
    new_kind = Vm.kind(merged["arch"] || "", merged["machine"] || "")

    if new_kind != old_kind do
      d = Vm.kind_defaults(new_kind, merged["machine"])

      Map.merge(merged, %{
        "memory" => to_string(d.memory),
        "cpus" => to_string(d.cpus),
        "net_model" => d.net_model
      })
    else
      merged
    end
  end

  defp form_errors(socket, params) do
    if socket.assigns.submitted do
      base = with({vm, _} <- current(socket), do: vm) || Vm.new(socket.assigns.settings)

      case Vm.cast(base, params) do
        {:ok, _} -> %{}
        {:error, errors} -> Map.new(errors)
      end
    else
      %{}
    end
  end

  defp qmp_result(socket, {:ok, _}), do: socket

  defp qmp_result(socket, {:error, :not_running}),
    do: put_flash(socket, :error, "A VM não está em execução")

  defp qmp_result(socket, {:error, msg}), do: put_flash(socket, :error, "QEMU: #{msg}")

  defp insert_cdrom(socket, id, path) do
    case VmStore.get(id) do
      {:ok, vm} ->
        result =
          if VmSupervisor.running?(id), do: VmServer.change_cdrom(id, path), else: {:ok, nil}

        case result do
          {:ok, _} ->
            VmStore.save(%{vm | cdrom: path})

            socket
            |> load_vms()
            |> prepare_view()
            |> put_flash(:info, "#{Path.basename(path)} no CD de #{vm.name}")

          {:error, msg} ->
            put_flash(socket, :error, "Não foi possível trocar o CD: #{inspect(msg)}")
        end

      _ ->
        socket
    end
  end

  defp picker_start(socket, target) do
    current_value =
      case target do
        "cdrom" -> socket.assigns.params["cdrom"]
        "disk:" <> i -> get_in(socket.assigns.params, ["disks", i, "path"])
        "cdrom_live" -> with({vm, _} <- current(socket), do: Vm.resolve(vm, vm.cdrom))
        "flash_app:" <> _ -> with({vm, _} <- current(socket), do: vm.app)
        target when target in ["avr_firmware", "cortexm_firmware"] ->
          with({vm, _} <- current(socket), do: vm.app)

        "workspace" -> Workspace.current()
        _ -> nil
      end

    cond do
      is_binary(current_value) and current_value != "" and Path.type(current_value) == :absolute and
          File.dir?(Path.dirname(current_value)) ->
        Path.dirname(current_value)

      String.starts_with?(target, "disk:") and match?({_, _}, current(socket)) ->
        {vm, _} = current(socket)
        Vm.dir(vm)

      target in ["import_image", "flash_bin"] or String.starts_with?(target, "flash") ->
        System.user_home() || ""

      File.dir?(Paths.images_dir()) ->
        Paths.images_dir()

      true ->
        System.user_home() || ""
    end
  end

  defp picker_cd(socket, nil, _dir), do: socket

  defp picker_cd(socket, picker, dir) do
    picker = Map.merge(%{entries: [], error: nil}, picker)

    case Files.list(dir, picker.exts) do
      {:ok, entries} ->
        assign(socket, picker: %{picker | entries: entries, error: nil} |> Map.put(:dir, dir))

      {:error, msg} ->
        assign(socket,
          picker: picker |> Map.put(:dir, dir) |> Map.put(:error, msg) |> Map.put(:entries, [])
        )
    end
  end

  defp pick(socket, path) do
    target = socket.assigns.picker && socket.assigns.picker.target
    socket = assign(socket, picker: nil)

    case target do
      "cdrom" ->
        assign(socket, params: Map.put(socket.assigns.params, "cdrom", path))

      "disk:" <> i ->
        disks = Map.get(socket.assigns.params, "disks", %{})
        disk = Map.get(disks, i, %{"format" => "qcow2", "interface" => "virtio"})
        format = Img.formats() |> Enum.find(disk["format"], &(Path.extname(path) == "." <> &1))
        disk = %{disk | "path" => path} |> Map.put("format", format)
        assign(socket, params: Map.put(socket.assigns.params, "disks", Map.put(disks, i, disk)))

      "cdrom_live" ->
        case current(socket) do
          {vm, _} -> insert_cdrom(socket, vm.id, path)
          nil -> socket
        end

      "new_vm_iso" ->
        new_vm(socket, iso_params(path))

      "workspace" ->
        open_workspace(socket, path)

      "tree_fw:" <> id ->
        with {vm, rt} <- find_vm(socket.assigns.vms, id),
             true <- stopped?(rt) || {:error, "Desligue a VM antes de trocar o firmware"},
             {:ok, file} <- QemuAdmin.Firmwares.add(vm, path) do
          socket = assign(socket, tree_open: Enum.uniq([id | socket.assigns.tree_open]))
          {_, socket} = use_firmware(socket, id, file)
          socket
        else
          {:error, msg} -> put_flash(socket, :error, msg)
          _ -> socket
        end

      "new_sd_image" ->
        assign(socket, params: Map.put(socket.assigns.params, "sd_image", path))

      "import_image" ->
        dest = Path.join(Paths.images_dir(), Path.basename(path))

        case File.cp(path, dest) do
          :ok ->
            socket
            |> load_images()
            |> put_flash(:info, "#{Path.basename(path)} copiado para o workspace")

          {:error, r} ->
            put_flash(socket, :error, "#{path}: #{:file.format_error(r)}")
        end

      target when target in ["avr_firmware", "cortexm_firmware"] ->
        with {vm, rt} <- current(socket),
             true <- stopped?(rt) || {:error, "Desligue a placa antes de gravar"} do
          firmware_write(socket, vm, path)
        else
          {:error, msg} -> put_flash(socket, :error, msg)
          _ -> socket
        end

      "sd_image" ->
        with {vm, rt} <- current(socket),
             true <- stopped?(rt) || {:error, "Desligue a placa antes de trocar o cartão"} do
          sd_import(socket, vm, path)
        else
          {:error, msg} -> put_flash(socket, :error, msg)
          _ -> socket
        end

      "flash_app:" <> partition ->
        flash_write(socket, path, &AtomVM.write_app(&1, path, partition), &%{&1 | app: path})

      "flash_bin" ->
        case EspFlash.parse_offset(socket.assigns.flash_offset) do
          {:ok, offset} ->
            write = fn flash ->
              with {:ok, data} <- File.read(path), do: EspFlash.write(flash, offset, data)
            end

            # a whole firmware (from the bootloader on) replaces what was there
            record = fn vm ->
              if offset <= EspFlash.bootloader_offset(vm.machine),
                do: %{vm | firmware: Path.basename(path), app: ""},
                else: vm
            end

            flash_write(socket, path, write, record)

          {:error, msg} ->
            put_flash(socket, :error, msg)
        end

      _ ->
        socket
    end
  end

  # Writes to the selected ESP32's flash (it must be off), then records what
  # went there on the VM.
  defp flash_write(socket, path, write, record) do
    with {vm, rt} <- current(socket),
         true <- stopped?(rt) || {:error, "Desligue o chip antes de gravar"},
         :ok <- write.(flash_path(vm)) do
      VmStore.save(record.(vm))

      socket
      |> load_vms()
      |> prepare_view()
      |> put_flash(:info, "#{Path.basename(path)} gravado na flash")
    else
      {:error, msg} -> put_flash(socket, :error, to_string(msg))
      _ -> socket
    end
  end

  defp shutdown_and_close(socket, timeout) do
    socket
    |> assign(close: :closing)
    |> start_async(:shutdown, fn -> VmSupervisor.shutdown_all(timeout) end)
  end

  defp tab_items(assigns) do
    for id <- assigns.tabs,
        {vm, rt} <- [find_vm(assigns.vms, id)],
        do: %{id: id, label: vm.name, status: rt.status}
  end

  defp running_count(vms), do: Enum.count(vms, fn {_, rt} -> running?(rt) end)

  defp vm_views(vm), do: Map.fetch!(@views, Vm.kind(vm))

  # A board's Visão geral: the UART's terminal and, beside it, the board — drawn with its
  # pins live where there is a drawing, else the VM's cards — to watch it whole.
  defp board_overview(assigns) do
    board = Vm.board(assigns.vm)
    assigns = assign(assigns, board: board, drawn?: board != nil and board.io != nil)

    ~F"""
    <div id="board-overview" class="flex min-h-0 flex-1">
      <SerialConsole vm={@vm} rt={@rt} />
      <aside
        id="board-side"
        class="flex min-h-0 w-[min(34rem,45%)] min-w-[16rem] shrink-0 flex-col overflow-y-auto border-l border-primary/20 bg-base-100"
      >
        {#if @drawn?}
          <Io vm={@vm} rt={@rt} board={@board} gpio={@gpio} />
        {#else}
          <Overview vm={@vm} rt={@rt} disk_info={@disk_info} command={@command} serial_tail={@serial_tail} compact />
        {/if}
      </aside>
    </div>
    """
  end

  # ------------------------------------------------------------------ view

  @impl true
  def render(assigns) do
    ~F"""
    <div class="flex h-screen w-screen flex-col overflow-hidden">
      <TitleBar />
      <div class="relative flex min-h-0 flex-1 overflow-hidden">
        <Sidebar
          expanded={@sidebar_expanded}
          current={@view}
          running={running_count(@vms)}
          themes={@themes}
        />

        <!-- width: dragged on its right edge (PanelResizer hook, kept in
             --side-panel-w on <html>); 18rem until then -->
        <aside
          id="side-panel"
          class="relative flex shrink-0 flex-col border-r border-primary/20 panel-glass"
          style="width: var(--side-panel-w, 18rem); max-width: 60vw"
        >
          <div
            id="side-panel-resizer"
            phx-hook="PanelResizer"
            class="side-panel-resizer"
            title="Arraste para redimensionar · duplo clique volta ao padrão"
          />
          {#if @view == "settings"}
            <SettingsNav section={@settings_section} />
          {#else}
            <VmList vms={@vms} selected={@selected} filter={@filter} workspaces={@workspaces} open={@tree_open} />
          {/if}
        </aside>

        <main class="flex min-w-0 flex-1 flex-col bg-base-100/60">
          {#if @view == "vms" and @mode == :new}
            {render_new(assigns)}
          {#elseif @view == "vms" and current(%{assigns: assigns})}
            {render_vm(assigns)}
          {#elseif @view == "vms"}
            {header_bar(assign(assigns, crumbs: ["Máquinas virtuais"]))}
            <Grid vms={@vms} qemu?={@qemu.dir != nil} />
          {#elseif @view == "disks"}
            {header_bar(assign(assigns, crumbs: ["Discos"]))}
            <Disks vms={@vms} disk_info={@disk_info} qemu?={@qemu.dir != nil} />
          {#elseif @view == "images"}
            {header_bar(assign(assigns, crumbs: ["Imagens", Workspace.name(Workspace.current())]))}
            <ImagesPage images={@images} dir={Paths.images_dir()} vms={@vms} download={@image_download} />
          {#elseif @view == "qemu"}
            {header_bar(assign(assigns, crumbs: ["QEMU"]))}
            <QemuPage qemu={@qemu} install={@install} install_esp={@install_esp} />
          {#elseif @view == "commands"}
            {header_bar(assign(assigns, crumbs: ["Comandos", "meus e do QEMU"]))}
            <CommandsPage
              cat={@cat}
              entries={Catalog.saved_entries(@cp_commands) ++ Catalog.all()}
              vm_name={vm_name(assigns)}
              commands={@cp_commands}
              vms={@vms}
              editing={@cp.editing}
              error={@cp.error}
              file_error={@cp_file_error}
              path={Saved.path()}
              lp={@lp}
              exes={Map.new(@vms, fn {vm, _} -> {vm.id, QemuAdmin.Qemu.exe_name(vm.arch)} end)}
              lines={launch_lines(@vms)}
            />
          {#else}
            {header_bar(
              assign(assigns, crumbs: ["Configurações", SettingsNav.section(@settings_section).label])
            )}
            <SettingsPage section={@settings_section} settings={@settings} />
          {/if}
        </main>
      </div>

      <Footer qemu={@qemu} running={running_count(@vms)} total={length(@vms)} />
      <Picker picker={@picker} />
      <CloseDialog
        state={@close}
        names={running_names(%{assigns: assigns})}
        timeout={@settings.stop_timeout}
      />
      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp tab_bar(assigns) do
    ~F"""
    <Tabs
      :if={@tabs != []}
      tabs={tab_items(assigns)}
      active={if @view == "vms" and is_nil(@mode), do: @selected}
    />
    """
  end

  defp crumbs(assigns) do
    ~F"""
    {#for {crumb, i} <- Enum.with_index(@crumbs)}
      <.icon :if={i > 0} name="hero-chevron-right" class="size-3 text-base-content/30" />
      <span class={if i == length(@crumbs) - 1, do: "font-semibold text-primary", else: "text-base-content/50"}>
        {crumb}
      </span>
    {/for}
    """
  end

  # The header of a page of the app (not of a VM): a title and the path.
  defp header_bar(assigns) do
    ~F"""
    <PageHeader>
      <:nav>
        <span class="font-semibold uppercase tracking-wider text-base-content/60">{Map.get(view_labels(), @view)}</span>
      </:nav>
      <:buttons>
        <IconButton
          :if={@view == "vms"}
          id="hdr-new-vm"
          title="Nova VM"
          click="new_vm"
          icon="hero-plus"
        />
      </:buttons>
      <:tabs>{tab_bar(assigns)}</:tabs>
      <:breadcrumb>{crumbs(assigns)}</:breadcrumb>
    </PageHeader>
    """
  end

  defp view_labels, do: @view_labels

  defp render_new(assigns) do
    ~F"""
    <PageHeader>
      <:nav><span class="font-semibold uppercase tracking-wider text-base-content/60">Nova VM</span></:nav>
      <:tabs>{tab_bar(assigns)}</:tabs>
      <:breadcrumb>{crumbs(assign(assigns, crumbs: ["Máquinas virtuais", "Nova VM"]))}</:breadcrumb>
    </PageHeader>
    <Form params={@params} errors={@errors} new emulators={@qemu.emulators} />
    """
  end

  defp render_vm(assigns) do
    {vm, rt} = current(%{assigns: assigns})
    assigns = assign(assigns, vm: vm, rt: rt)

    ~F"""
    <PageHeader>
      <:nav>
        <StatusDot status={@rt.status} label />
        <span class="truncate font-semibold">{@vm.name}</span>
      </:nav>
      <:center>
        <div class="flex items-center rounded border border-primary/20 p-0.5" role="tablist">
          {#for {key, label, icon} <- vm_views(@vm)}
            <button
              type="button"
              id={"vm-view-#{key}"}
              phx-click="vm_view"
              phx-value-view={key}
              role="tab"
              title={label}
              aria-selected={to_string(@vm_view == key)}
              class={
                "flex items-center gap-1.5 rounded-sm px-2.5 py-1 text-[0.7rem] transition-colors",
                "bg-primary/15 text-primary font-semibold": @vm_view == key,
                "text-base-content/55 hover:text-base-content": @vm_view != key
              }
            >
              <.icon name={icon} class="size-3.5" />
              <span class="hidden xl:inline">{label}</span>
            </button>
          {/for}
        </div>
      </:center>
      <:buttons>
        {#if (@vm_view == "console" and Vm.mcu?(@vm)) or @vm_view == "serial"}
          <IconButton
            id="serial-clear"
            title="Limpar o terminal"
            click={Phoenix.LiveView.JS.dispatch("qa:serial-clear")}
            icon="hero-no-symbol"
          />
          <span class="mx-1 h-4 w-px bg-base-content/15" />
        {/if}
        {#if @vm_view == "console" and running?(@rt) and @vm.display == "vnc"}
          <IconButton id="vnc-cad" title="Ctrl+Alt+Del" click={Phoenix.LiveView.JS.dispatch("qa:vnc-cad")}>
            C-A-Del
          </IconButton>
          <IconButton
            id="vnc-scale"
            title="Ajustar à janela / tamanho real"
            click={Phoenix.LiveView.JS.dispatch("qa:vnc-scale")}
            icon="hero-arrows-pointing-in"
          />
          <IconButton
            id="vnc-fullscreen"
            title="Tela cheia"
            click={Phoenix.LiveView.JS.dispatch("qa:vnc-fullscreen")}
            icon="hero-arrows-pointing-out"
          />
          <span class="mx-1 h-4 w-px bg-base-content/15" />
        {/if}
        {#if stopped?(@rt)}
          <IconButton
            id="vm-start"
            title="Ligar"
            click="start_vm"
            value={@vm.id}
            icon="hero-play-solid"
            tone="success"
            disabled={is_nil(@qemu.dir)}
          />
          <IconButton
            id="vm-clone"
            title="Clonar"
            click="clone_vm"
            value={@vm.id}
            icon="hero-document-duplicate"
          />
          <IconButton
            id="vm-delete"
            title="Excluir VM"
            click="delete_vm"
            value={@vm.id}
            icon="hero-trash"
            tone="error"
            confirm={"Excluir \"#{@vm.name}\"? A pasta da VM, com os discos dentro dela, vai junto."}
          />
        {#else}
          {#if paused?(@rt)}
            <IconButton
              id="vm-resume"
              title="Continuar"
              click="resume_vm"
              value={@vm.id}
              icon="hero-play-solid"
              tone="success"
            />
          {#else}
            <IconButton
              id="vm-pause"
              title="Pausar"
              click="pause_vm"
              value={@vm.id}
              icon="hero-pause-solid"
            />
          {/if}
          <IconButton
            id="vm-reset"
            title="Reiniciar (reset)"
            click="reset_vm"
            value={@vm.id}
            icon="hero-arrow-path"
            tone="warning"
            confirm="Reiniciar a VM agora? É como apertar o botão de reset."
          />
          <IconButton
            id="vm-powerdown"
            title={if Vm.board(@vm), do: "Desligar (cortar a energia)", else: "Desligar (ACPI)"}
            click="powerdown_vm"
            value={@vm.id}
            icon="hero-power"
            tone="warning"
          />
          <IconButton
            :if={is_nil(Vm.board(@vm))}
            id="vm-quit"
            title="Forçar desligamento"
            click="quit_vm"
            value={@vm.id}
            icon="hero-bolt-slash"
            tone="error"
            confirm="Forçar o desligamento? É como tirar da tomada."
          />
        {/if}
      </:buttons>
      <:tabs>{tab_bar(assigns)}</:tabs>
      <:breadcrumb>
        {crumbs(
          assign(assigns,
            crumbs: [
              "Máquinas virtuais",
              @vm.name,
              Enum.find_value(vm_views(@vm), fn {k, l, _} -> k == @vm_view && l end)
            ]
          )
        )}
      </:breadcrumb>
    </PageHeader>
    {#case @vm_view}
      {#match "console"}
        {#if Vm.mcu?(@vm)}
          <SerialConsole vm={@vm} rt={@rt} />
        {#else}
          <Console vm={@vm} rt={@rt} />
        {/if}
      {#match "serial"}
        <SerialConsole vm={@vm} rt={@rt} />
      {#match "io"}
        <Io vm={@vm} rt={@rt} board={Vm.board(@vm)} gpio={@gpio} />
      {#match "firmware"}
        {#if Vm.kind(@vm) == :cortexm}
          <CortexFirmware vm={@vm} rt={@rt} file={Args.cortexm_firmware(@vm)} />
        {#else}
          <Firmware vm={@vm} rt={@rt} file={Args.avr_firmware(@vm)} />
        {/if}
      {#match "sd"}
        <SdCard vm={@vm} rt={@rt} board={Vm.board(@vm)} import={@sd_import} user={@sd_user} />
      {#match "flash"}
        <Flash
          :if={@esp_flash}
          vm={@vm}
          rt={@rt}
          flash={@esp_flash}
          atomvm={@atomvm}
          offset={@flash_offset}
        />
      {#match "config"}
        <Form params={@params} errors={@errors} running={running?(@rt)} emulators={@qemu.emulators} />
      {#match "log"}
        <Log lines={@streams.log} />
      {#match _}
        {#if Vm.mcu?(@vm)}
          {board_overview(assigns)}
        {#else}
          <Overview
            vm={@vm}
            rt={@rt}
            disk_info={@disk_info}
            command={@command}
            serial_tail={@serial_tail}
          />
        {/if}
    {/case}
    <Terminal
      vm={@vm}
      rt={@rt}
      entries={@streams.cmds}
      history={@cmd_history}
      open={@cmds_open}
      saved={@saved}
    />
    """
  end
end
