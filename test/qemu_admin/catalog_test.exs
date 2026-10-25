defmodule QemuAdmin.Terminal.CatalogTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Terminal.Catalog

  test "the catalog has the four kinds" do
    kinds = Catalog.all() |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
    assert kinds == ["event", "hmp", "qmp", "tool"]
    assert %{kind: "qmp", name: "stop"} = Catalog.get("qmp:stop")
  end

  test "search: every word, prefixes, accents and case ignored; exact name first" do
    {total, [first | _]} = Catalog.search("STOP")
    assert total > 1
    assert first.name == "stop"

    {_, found} = Catalog.search("UTILITÁRIO")
    assert found != []

    # AND of the words
    {_, found} = Catalog.search("block device")
    assert Enum.all?(found, fn e ->
             text = Catalog.normalize(e.name <> " " <> e.usage <> " " <> e.description <> " " <> Enum.map_join(e.args, " ", &(&1.name <> " " <> &1.description)))
             String.contains?(text, "block") and String.contains?(text, "device")
           end)

    assert {0, []} = Catalog.search("   ")
    assert {0, []} = Catalog.search("zzzqqqxxx")
  end

  test "narrow: by kind and by name or description" do
    all = Catalog.all()
    assert Enum.all?(Catalog.narrow(all, "hmp", ""), &(&1.kind == "hmp"))
    assert Enum.any?(Catalog.narrow(all, "qmp", "stop"), &(&1.name == "stop"))
    assert Catalog.narrow(all, "all", "zzzqqqxxx") == []
  end

  test "line: the step for each kind" do
    assert Catalog.line(Catalog.get("qmp:stop"), %{}) == "qmp: stop"
    assert Catalog.line(Catalog.get("event:RESUME"), %{}) == nil

    e = Catalog.get("qmp:eject")
    line = Catalog.line(e, %{"id" => "cd0", "force" => "true"})
    assert "qmp: eject " <> json = line
    assert %{"id" => "cd0", "force" => true} = Jason.decode!(json)

    assert Catalog.line(Catalog.get("hmp:balloon"), %{"target" => "512"}) == "hmp: balloon 512"
    assert Catalog.line(Catalog.get("tool:qemu-img"), %{"args" => "info disk.qcow2"}) == "cli: qemu-img info disk.qcow2"
  end

  test "every line it builds for a bare command is a valid saved step" do
    for e <- Catalog.all(), e.kind in ["hmp", "qmp"], line = Catalog.line(e, %{}) do
      assert line =~ ~r/^(qmp|hmp): /
    end
  end
end
