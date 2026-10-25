defmodule QemuAdminWeb.TerminalControllerTest do
  use QemuAdminWeb.ConnCase, async: true

  test "serves the catalog the Terminal's prompt suggests from", %{conn: conn} do
    conn = get(conn, "/terminal/commands.json")

    assert response(conn, 200)
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/json"
    assert [cache] = get_resp_header(conn, "cache-control")
    assert cache =~ "max-age"

    catalog = Jason.decode!(conn.resp_body)
    assert Enum.any?(catalog["hmp"], &(&1["name"] == "info registers"))
    assert Enum.any?(catalog["qmp"], &(&1["name"] == "query-status"))
  end
end
