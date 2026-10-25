defmodule QemuAdminWeb.Router do
  use QemuAdminWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {QemuAdminWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", QemuAdminWeb do
    pipe_through :browser

    # The whole app is one LiveView, as the Rockwell Viewer: the rail, the
    # side panel and the page all live in it.
    live "/", AdminLive, :index
  end

  scope "/", QemuAdminWeb do
    # the screenshot QEMU writes every few seconds (VM list, overview)
    get "/vms/:id/screen.png", ScreenController, :show

    # the commands the Terminal's prompt suggests from
    get "/terminal/commands.json", TerminalController, :catalog
  end
end
