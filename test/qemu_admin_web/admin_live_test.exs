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
