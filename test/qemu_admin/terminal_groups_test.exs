defmodule QemuAdmin.TerminalGroupsTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Terminal.Groups

  defp e(seq, dir, text, extra \\ %{}),
    do: Map.merge(%{seq: seq, at: "2026-10-25T10:00:00Z", dir: dir, text: text}, extra)

  defp history, do: [
    e(1, "launch", "qemu-system-arm ..."),
    e(2, "cmd", "Pausar", %{x: 2, src: "botão", via: "QMP"}),
    e(3, "sent", ~s({"execute":"stop","id":4}), %{x: 2}),
    e(4, "received", ~s({"return":{},"id":4}), %{x: 2}),
    e(5, "event", "STOP", %{x: 2}),
    e(6, "event", "RESUME"),
    e(7, "cmd", "resume", %{x: 7, src: "digitado", via: "monitor (HMP)"}),
    e(8, "sent", "...", %{x: 7}),
    e(9, "received", "unknown command: 'resume'", %{x: 7}),
    e(10, "cmd", "info x", %{x: 10, src: "digitado", via: "monitor (HMP)"}),
    e(11, "sent", "...", %{x: 10}),
    e(12, "error", "boom", %{x: 10})
  ]

  test "build/1: a row per command, with its lines inside; a line with no x is a row of its own" do
    {_groups, rows} = Groups.build(history())

    assert [1, 2, 6, 7, 10] = Enum.map(rows, & &1.seq)
    assert [%{seq: 3}, %{seq: 4}, %{seq: 5}] = Enum.at(rows, 1).items
    assert [] = Enum.at(rows, 0).items
  end

  test "add/2 returns the row again as lines arrive, so it is updated in place" do
    {groups, row} = Groups.add(%{}, e(2, "cmd", "Pausar", %{x: 2}))
    assert row.items == [] and Groups.status(row) == :waiting

    {groups, row} = Groups.add(groups, e(3, "sent", "x", %{x: 2}))
    assert row.seq == 2
    assert [%{seq: 3}] = row.items

    {_groups, row} = Groups.add(groups, e(4, "received", "ok", %{x: 2}))
    assert [%{seq: 3}, %{seq: 4}] = row.items
    assert Groups.status(row) == :done and Groups.preview(row) == "ok"
  end

  test "a line that comes twice (in the loaded history and as a message on its way) counts once" do
    {groups, rows} = Groups.build(history())
    pause = Enum.at(rows, 1)

    {groups, again} = Groups.add(groups, e(4, "received", "dup", %{x: 2}))
    assert again.items == pause.items

    {_groups, again} = Groups.add(groups, e(2, "cmd", "Pausar", %{x: 2, src: "botão", via: "QMP"}))
    assert again.items == pause.items
  end

  test "a line whose command is gone stands alone" do
    {groups, row} = Groups.add(%{}, e(40, "received", "late", %{x: 3}))
    assert groups == %{} and row.seq == 40 and row.items == []
  end

  test "status/1 and preview/1" do
    {_g, rows} = Groups.build(history())
    assert [nil, :done, nil, :done, :error] = Enum.map(rows, &Groups.status/1)
    assert Enum.at(rows, 4) |> Groups.preview() == "boom"
    assert Enum.at(rows, 3) |> Groups.preview() == "unknown command: 'resume'"
  end
end
