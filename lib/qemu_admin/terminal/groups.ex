defmodule QemuAdmin.Terminal.Groups do
  @moduledoc """
  Folds the flat command history (`QemuAdmin.VmServer.commands/1`) into what the
  Terminal shows: one **row** per command, which opens to what really went to
  QEMU, the answer and the events.

  An entry of the history is a `"cmd"` line (its `text` is what the user sees as
  the command, `src` where it came from — `"digitado"`, `"botão"`, `"salvo: start
  (passo 2/4)"`, `"app"` — and `via` how it reaches QEMU) followed by the lines
  with the same `x`: `"sent"` (the exact QMP message, or the process), `"received"`,
  `"event"`, `"error"`. A line with no `x` (the launch command, a saved command's
  `▶`, an event nobody asked for, anything an older `commands.log` has) is a row
  by itself.

  A row is the entry with `items`: the lines that belong to it, in order. `add/2`
  is for a line that has just arrived (it returns the row to insert again, in
  place); `build/1` for a whole history.
  """

  # groups kept open for lines to come; the oldest are let go
  @keep 300

  @type groups :: %{optional(integer) => map}

  @doc "`{groups, row}`: the row `entry` makes or changes."
  @spec add(groups, map) :: {groups, map}
  # (a line may come twice — once in the history the page loaded, once as a message
  # that was already on its way — so one already in the row changes nothing)
  def add(groups, %{dir: "cmd", seq: seq, x: x} = entry) do
    case groups do
      %{^x => %{seq: ^seq} = row} ->
        {groups, row}

      _ ->
        row = Map.put(entry, :items, [])
        {groups |> Map.put(x, row) |> prune(), row}
    end
  end

  def add(groups, %{x: x, seq: seq} = entry) when is_integer(x) do
    case groups do
      %{^x => row} ->
        if Enum.any?(row.items, &(&1.seq == seq)) do
          {groups, row}
        else
          row = %{row | items: row.items ++ [entry]}
          {Map.put(groups, x, row), row}
        end

      _ ->
        {groups, Map.put(entry, :items, [])}
    end
  end

  def add(groups, entry), do: {groups, Map.put(entry, :items, [])}

  @doc "`{groups, rows}` for a whole history (oldest first)."
  @spec build([map]) :: {groups, [map]}
  def build(entries) do
    {groups, seen} =
      Enum.reduce(entries, {%{}, []}, fn entry, {groups, seen} ->
        {groups, row} = add(groups, entry)
        {groups, [{row.seq, row} | seen]}
      end)

    seen = Enum.reverse(seen)
    latest = Map.new(seen)

    rows = seen |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.map(&Map.fetch!(latest, &1))
    {groups, rows}
  end

  @doc "How a row went: `:error`, `:done` (answered) or `:waiting`; `nil` for a row that is no command."
  @spec status(map) :: :error | :done | :waiting | nil
  def status(%{dir: "cmd", items: items}) do
    cond do
      Enum.any?(items, &(&1.dir == "error")) -> :error
      Enum.any?(items, &(&1.dir == "received")) -> :done
      true -> :waiting
    end
  end

  def status(_row), do: nil

  @doc "The first line of the last answer (or error) of a row, to show beside it when closed."
  @spec preview(map) :: String.t()
  def preview(%{items: items}) do
    case items |> Enum.filter(&(&1.dir in ["received", "error"])) |> List.last() do
      nil -> ""
      %{text: text} -> text |> String.split(~r/\R/, parts: 2) |> hd() |> String.slice(0, 120)
    end
  end

  defp prune(groups) when map_size(groups) > @keep do
    groups |> Map.keys() |> Enum.sort() |> Enum.take(map_size(groups) - @keep) |> then(&Map.drop(groups, &1))
  end

  defp prune(groups), do: groups
end
