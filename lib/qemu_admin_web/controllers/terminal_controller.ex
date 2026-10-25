defmodule QemuAdminWeb.TerminalController do
  @moduledoc """
  Serves the catalog of QEMU's commands (`priv/terminal/commands.json`, see
  `tools/gen_qemu_catalog.py`) to the Terminal's prompt, which suggests from it
  as one types. It only changes with the app, so the browser may keep it.
  """

  use QemuAdminWeb, :controller

  def catalog(conn, _params) do
    path = Path.join([:code.priv_dir(:qemu_admin), "terminal", "commands.json"])

    if File.regular?(path) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "")
    end
  end
end
