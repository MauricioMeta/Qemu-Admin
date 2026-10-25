defmodule QemuAdminWeb.ScreenController do
  @moduledoc """
  Serves a VM's last screenshot (`screen.png` in its folder, written by
  `QemuAdmin.VmServer` through QMP). The page adds `?v=<rev>` to the URL so
  each new one is fetched; this response is never cached.
  """

  use QemuAdminWeb, :controller

  alias QemuAdmin.Paths

  def show(conn, %{"id" => id}) do
    path = Path.join(Paths.vm_dir(id), "screen.png")

    if Regex.match?(~r/^[a-z0-9][a-z0-9\-_.]*$/i, id) and File.regular?(path) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header("cache-control", "no-store")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "")
    end
  end
end
