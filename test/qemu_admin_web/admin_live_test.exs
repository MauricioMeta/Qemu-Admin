defmodule QemuAdminWeb.AdminLiveTest do
  use QemuAdminWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QemuAdmin.{Paths, Settings, VmStore}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  test "the shell: rail, empty VM list, footer", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Máquinas virtuais"
    assert html =~ "Nenhuma VM neste workspace"
    assert has_element?(view, "#nav-disks")
    assert has_element?(view, "#footer-qemu")
  end

  test "creating a VM from the form opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#new-vm") |> render_click()
    assert has_element?(view, "#vm-form")

    # no disk: qemu-img is not needed for this test
    view
    |> form("#vm-form", vm: %{name: "Alpine", memory: "512", disk_size: ""})
    |> render_submit()

    assert [%{id: "alpine", memory: 512}] = VmStore.list()
    assert has_element?(view, "#vm-row-alpine[aria-current=page]")
    assert has_element?(view, "#vm-overview")
    assert has_element?(view, "#tab-0", "Alpine")
  end

  test "folding and unfolding the Terminal does not crash the page", %{conn: conn} do
    {:ok, _vm} = VmStore.create(%{"name" => "Box"})
    {:ok, view, _html} = live(conn, "/")
    view |> element("#vm-row-box") |> render_click()
    assert has_element?(view, "#vm-terminal")
    assert has_element?(view, "#vm-cmds")

    view |> element("#cmds-toggle") |> render_click()
    assert has_element?(view, "#vm-terminal")
    refute has_element?(view, "#vm-cmds")

    view |> element("#cmds-toggle") |> render_click()
    assert has_element?(view, "#vm-cmds")
  end

  test "the history is still there after folding the Terminal; Limpar empties it", %{conn: conn} do
    {:ok, vm} = VmStore.create(%{"name" => "Box"})
    QemuAdmin.Terminal.log(vm.id, "error", "uma linha antiga")
    {:ok, view, _html} = live(conn, "/")
    view |> element("#vm-row-box") |> render_click()
    assert render(view) =~ "uma linha antiga"

    view |> element("#cmds-toggle") |> render_click()
    refute has_element?(view, "#vm-cmds")
    view |> element("#cmds-toggle") |> render_click()
    assert render(view) =~ "uma linha antiga"

    view |> element("#cmds-clear") |> render_click()
    refute render(view) =~ "uma linha antiga"
    assert QemuAdmin.VmServer.commands(vm.id) == []

    # the buttons that moved to the Comandos page are not in the Terminal any more
    refute has_element?(view, "#saved-open")
    refute has_element?(view, "#cmd-edit")
  end

  test "the launch line is edited on the Comandos page", %{conn: conn} do
    {:ok, vm} = VmStore.create(%{"name" => "Box"})
    {:ok, view, _html} = live(conn, "/")
    view |> element("#nav-commands") |> render_click()
    view |> element("#cat-tab-launch") |> render_click()
    assert has_element?(view, "#lp-#{vm.id}")

    view |> element("#lp-#{vm.id} button", "Editar linha de partida") |> render_click()
    assert has_element?(view, "#lp-form")

    # without what the app needs to control the VM it is refused
    html = view |> form("#lp-form", text: "-machine q35") |> render_submit()
    assert html =~ "{qmp}"
    assert {:ok, %{command: ""}} = VmStore.get(vm.id)

    view |> element("#lp-cancel") |> render_click()
    refute has_element?(view, "#lp-form")
  end

  test "the Comandos page: a rail icon, and creating, editing and deleting a saved command", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#nav-commands") |> render_click()
    assert has_element?(view, "#commands-page")
    view |> element("#cat-tab-saved") |> render_click()
    assert render(view) =~ "Nenhum comando salvo ainda"

    view |> element("#cp-new") |> render_click()
    assert has_element?(view, "#cp-form")

    # a step that cannot run is refused, with the reason, and nothing is written
    html =
      view
      |> form("#cp-form", saved: %{name: "ruim", steps: "cli: info status"})
      |> render_submit()

    assert html =~ "cli: só roda as ferramentas do QEMU"
    assert {:ok, []} = QemuAdmin.Terminal.Saved.load()

    view |> form("#cp-form", saved: %{name: "parar", description: "pausa", steps: "qmp: stop"}) |> render_submit()
    refute has_element?(view, "#cp-form")
    assert has_element?(view, "#cp-parar", "qmp: stop")

    # the saved command is found by the same search as QEMU's own
    html = view |> form("#cat-search-form", q: "pausa") |> render_change()
    assert html =~ "cat-results"
    assert has_element?(view, "#cat-results button[phx-value-id='saved:parar']")
    assert [%{"name" => "parar", "steps" => ["qmp: stop"]}] = QemuAdmin.Terminal.Saved.list("qualquer")

    view |> element("#cp-parar button[phx-click=cp_edit]") |> render_click()
    assert has_element?(view, "#cp-form")
    view |> form("#cp-form", saved: %{name: "pausar", steps: "qmp: stop
hmp: info status"}) |> render_submit()
    assert has_element?(view, "#cp-pausar")
    refute has_element?(view, "#cp-parar")

    view |> element("#cp-pausar button[phx-click=cp_delete]") |> render_click()
    refute has_element?(view, "#cp-pausar")
    assert {:ok, []} = QemuAdmin.Terminal.Saved.load()
  end

  test "the form says what is missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#new-vm") |> render_click()
    html = view |> form("#vm-form", vm: %{name: "", disk_size: ""}) |> render_submit()
    assert html =~ "dê um nome à VM"
    assert VmStore.list() == []
  end

  test "VM views and settings sections", %{conn: conn} do
    {:ok, _vm} = VmStore.create(%{"name" => "Box"})
    {:ok, view, _html} = live(conn, "/")

    view |> element("#vm-row-box") |> render_click()
    view |> element("#vm-view-config") |> render_click()
    assert has_element?(view, "#vm-form input[name='vm[name]'][value='Box']")

    view |> element("#vm-view-log") |> render_click()
    assert has_element?(view, "#vm-log")

    view |> element("#nav-settings") |> render_click()
    view |> element("#settings-section-general") |> render_click()
    view |> form("#setting-stop_timeout", %{key: "stop_timeout", value: "12"}) |> render_change()
    assert Settings.get(:stop_timeout) == 12
  end

  test "closing the window with nothing running closes at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_hook(view, "window_close", %{})
    assert_push_event(view, "qa:close-window", %{})
  end

  test "the Catálogo page: search, table filter, argument editor, adding a step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#nav-commands") |> render_click()
    assert has_element?(view, "#commands-page")
    view |> form("#cat-filter", q: "stop") |> render_change()
    assert has_element?(view, "[id='cat-row-qmp:stop']")

    # the table filter narrows by name or description
    view |> form("#cat-filter", q: "zzzqqqxxx") |> render_change()
    assert render(view) =~ "Nenhum comando com esse filtro"
    view |> form("#cat-filter", q: "") |> render_change()
    view |> element("#cat-tab-event") |> render_click()
    refute has_element?(view, "[id='cat-row-qmp:stop']")
    view |> element("#cat-tab-all") |> render_click()

    # the full-text search lists results; picking one opens its editor
    html = view |> form("#cat-search-form", q: "eject") |> render_change()
    assert html =~ "cat-results"
    view |> element("#cat-results button[phx-value-id='qmp:eject']") |> render_click()
    assert has_element?(view, "#cat-editor-row")

    view |> form("#cat-form", v: %{"id" => "cd0"}, to: "") |> render_change()
    assert view |> element("#cat-line") |> render() =~ "qmp: eject"

    # no VM selected: nothing to send to
    assert has_element?(view, "#cat-send[disabled]")

    # as a step of a new saved command: the Comandos form opens with it
    view |> element("#cat-step") |> render_click()
    assert has_element?(view, "#cp-form")
    assert render(view) =~ "qmp: eject"
  end

  test "the Catálogo adds a step to an existing saved command", %{conn: conn} do
    :ok = QemuAdmin.Terminal.Saved.save(%{"name" => "parar", "description" => "", "vm" => nil, "steps" => ["qmp: stop"], "continue_on_error" => false})
    {:ok, view, _html} = live(conn, "/")
    view |> element("#nav-commands") |> render_click()
    view |> form("#cat-filter", q: "cont") |> render_change()
    view |> element("[id='cat-row-qmp:cont']") |> render_click()
    view |> form("#cat-form", to: "parar") |> render_change()
    view |> element("#cat-step") |> render_click()
    assert [%{"steps" => ["qmp: stop", "qmp: cont"]}] = QemuAdmin.Terminal.Saved.list("x")
  end

  test "the side panel groups the VMs by engine and opens a board onto its firmwares", %{conn: conn} do
    {:ok, vm} = VmStore.create(%{"name" => "Placa", "arch" => "arm", "machine" => "netduinoplus2"})
    {:ok, pc} = VmStore.create(%{"name" => "Servidor"})
    dir = QemuAdmin.Vm.dir(vm)
    File.mkdir_p!(Path.join(dir, "firmware"))
    File.write!(Path.join(dir, "firmware/a.elf"), "x")
    File.write!(Path.join(dir, "firmware/b.elf"), "x")

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#engine-qemu")
    refute has_element?(view, "#engine-renode")

    # a PC has no firmwares to open; a board does
    refute has_element?(view, "#vm-toggle-#{pc.id}")
    refute has_element?(view, "#fw-list-#{vm.id}")
    view |> element("#vm-toggle-#{vm.id}") |> render_click()
    assert has_element?(view, "[id='fw-#{vm.id}-a.elf']")
    assert has_element?(view, "[id='fw-#{vm.id}-b.elf']")

    # picking one makes it the program and opens the VM
    view |> element("[id='fw-#{vm.id}-b.elf'] button[phx-click=pick_firmware]") |> render_click()
    assert {:ok, %{program: "firmware/b.elf"}} = VmStore.get(vm.id)
    assert has_element?(view, "[id='fw-#{vm.id}-b.elf'] .hero-check-circle")
    refute has_element?(view, "[id='fw-#{vm.id}-a.elf'] .hero-check-circle")
  end
end
