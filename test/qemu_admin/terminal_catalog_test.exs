defmodule QemuAdmin.TerminalCatalogTest do
  use ExUnit.Case, async: true

  # priv/terminal/commands.json, made by tools/gen_qemu_catalog.py from the QEMU
  # in use and its QAPI docs: what the terminal offers as you type.
  @path Path.join([:code.priv_dir(:qemu_admin), "terminal", "commands.json"])

  setup_all do
    {:ok, catalog: @path |> File.read!() |> Jason.decode!()}
  end

  test "has the three lists, and where it comes from", %{catalog: c} do
    assert c["version"] == 1
    assert c["qemu"] =~ ~r/^\d+\.\d+\.\d+$/
    assert is_binary(c["generated"]) and is_binary(c["about"])
    assert [_ | _] = c["hmp"]
    assert [_ | _] = c["qmp"]
    assert [_ | _] = c["qmp_events"]
  end

  test "every entry has a name, a description and the emulators that have it", %{catalog: c} do
    for list <- ["hmp", "qmp", "qmp_events"], entry <- c[list] do
      assert is_binary(entry["name"]) and entry["name"] != "", list
      assert is_binary(entry["description"]), entry["name"]
      assert [_ | _] = entry["emulators"], entry["name"]
    end

    for list <- ["hmp", "qmp", "qmp_events", "tools"] do
      names = Enum.map(c[list], & &1["name"])
      assert names == Enum.uniq(names), "#{list} has repeated names"
    end
  end

  test "describes (almost) everything", %{catalog: c} do
    assert Enum.all?(c["hmp"], &(&1["description"] != ""))
    # QEMU itself leaves a couple of its own commands undocumented
    assert Enum.count(c["qmp"], &(&1["description"] == "")) <= 3
    assert Enum.all?(c["qmp_events"], &(&1["description"] != ""))
  end

  test "the monitor commands: usage, aliases and the info group", %{catalog: c} do
    hmp = Map.new(c["hmp"], &{&1["name"], &1})

    assert hmp["stop"]["aliases"] == ["s"]
    assert hmp["info registers"]["usage"] =~ "vcpu"
    assert hmp["info registers"]["description"] =~ "registers"
    assert hmp["drive_add"]["usage"] =~ "file=file"
    assert Enum.count(c["hmp"], &String.starts_with?(&1["name"], "info ")) > 30
    refute Enum.any?(c["hmp"], &String.starts_with?(&1["name"], "["))
  end

  test "the QMP commands: arguments with type, required and description", %{catalog: c} do
    qmp = Map.new(c["qmp"], &{&1["name"], &1})

    assert qmp["stop"]["arguments"] == []
    assert qmp["query-status"]["description"] =~ "run status"

    assert %{"arguments" => args} = qmp["blockdev-change-medium"]
    filename = Enum.find(args, &(&1["name"] == "filename"))
    assert %{"type" => "str", "required" => true, "description" => "filename" <> _} = filename

    mode = Enum.find(args, &(&1["name"] == "read-only-mode"))
    assert mode["type"] == "enum" and "read-write" in mode["values"]

    # the commands the app itself sends
    for name <- ~w(system_powerdown system_reset stop cont quit eject query-status screendump) do
      assert qmp[name] || c["hmp"] |> Enum.any?(&(&1["name"] == name)), name
    end
  end

  test "the tools that need no VM: qemu-img's commands, qemu-io and the qemu-system helps", %{catalog: c} do
    tools = Map.new(c["tools"], &{&1["name"], &1})

    for sub <- ~w(create info convert resize snapshot check) do
      assert %{"description" => d} = tools["qemu-img #{sub}"], sub
      assert d != ""
    end

    assert tools["qemu-img create"]["usage"] =~ "FILE"
    assert tools["qemu-img"]["usage"] =~ "COMMAND"
    assert tools["qemu-io"]["usage"] =~ "-c"
    assert %{"emulators" => ["arm"]} = tools["qemu-system-arm -machine help"]
    assert tools["qemu-system-x86_64 -cpu help"]
  end

  test "the events", %{catalog: c} do
    events = Map.new(c["qmp_events"], &{&1["name"], &1})
    for name <- ~w(STOP RESUME SHUTDOWN RESET POWERDOWN), do: assert(events[name], name)
    assert events["SHUTDOWN"]["data"] |> Enum.any?(&(&1["name"] == "reason"))
  end
end
