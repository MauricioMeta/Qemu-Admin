defmodule QemuAdminWeb.TerminalControllerTest do
  use QemuAdminWeb.ConnCase, async: true

  test "serves the catalog the Terminal's prompt suggests from", %{conn: conn} do
    conn = get(conn, "/terminal/commands.json")

    assert response(conn, 200)
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/json"

    catalog = Jason.decode!(conn.resp_body)
    assert Enum.any?(catalog["hmp"], &(&1["name"] == "info registers"))
    assert Enum.any?(catalog["qmp"], &(&1["name"] == "query-status"))
    assert Enum.any?(catalog["tools"], &(&1["name"] == "qemu-img create"))
  end

  test "the browser is asked to check whether it changed, and told it did not", %{conn: conn} do
    first = get(conn, "/terminal/commands.json")
    assert [etag] = get_resp_header(first, "etag")
    assert ["no-cache"] = get_resp_header(first, "cache-control")

    again =
      conn
      |> put_req_header("if-none-match", etag)
      |> get("/terminal/commands.json")

    assert response(again, 304) == ""
  end
end
