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
end
