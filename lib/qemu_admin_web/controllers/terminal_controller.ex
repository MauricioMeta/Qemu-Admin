defmodule QemuAdminWeb.TerminalController do
  @moduledoc """
  Serves the catalog of QEMU's commands (`priv/terminal/commands.json`, see
  `tools/gen_qemu_catalog.py`) to the Terminal's prompt, which suggests from it
  as one types. The browser keeps it but asks each time whether it changed
  (an ETag from the file's size and date): the catalog is regenerated when
  QEMU is updated.
  """

  use QemuAdminWeb, :controller

  def catalog(conn, _params) do
    path = Path.join([:code.priv_dir(:qemu_admin), "terminal", "commands.json"])

    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        etag = ~s("#{size}-#{mtime}")

        conn =
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "no-cache")

        if etag in get_req_header(conn, "if-none-match") do
          send_resp(conn, 304, "")
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_file(200, path)
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end
end
