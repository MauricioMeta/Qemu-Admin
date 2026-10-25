defmodule QemuAdmin.Terminal.Catalog do
  @moduledoc """
  The catalog of QEMU's commands (`priv/terminal/commands.json`, made by
  `tools/gen_qemu_catalog.py`) as the **Catálogo** page reads it: one flat list of
  entries and a full-text search over it.

  An entry is `%{id, kind, name, usage, description, since, args, emulators}`:

    * `kind` — `"hmp"` (monitor command), `"qmp"`, `"event"` (QMP event, not
      executable), `"tool"` (a QEMU program: `qemu-img`, `qemu-io`…) or `"saved"`
      (a command of the user, from `terminal.json`: see `saved_entries/1`; it
      is not in `all/0`, the page adds it, and `search/2` and `get/2` take it in
      their `extra` option);
    * `args` — `[%{name, type, required, description}]`: a QMP command's
      arguments from the schema, a monitor command's from its usage line
      (`[interfaces] [id]` is two optional ones), a tool's a single free `args`.

  `search/2` is the page's FTS: the text is cut into words, a word matches the
  tokens that *start* with it, a document needs **every** word, and the score adds
  the weight of the field where each was found (name > arguments > description),
  three times that when the token is the word itself. Accents and case are ignored.
  The index (a list of `{entry, %{token => weight}}`, ~600 rows) is built once and
  kept in `:persistent_term`; a scan of it is a fraction of a millisecond.

  `line/2` builds the step a filled-in entry stands for (`qmp: stop`,
  `hmp: balloon 512`, `cli: qemu-img info disk.qcow2`), the same text the Terminal
  and the saved commands run.
  """

  @key {__MODULE__, :index}
  @kinds ~w(saved hmp qmp event tool)
  @limit 40

  @doc "The kinds, in the order the page lists them."
  def kinds, do: @kinds

  @doc "Every entry, sorted by kind and name."
  @spec all() :: [map()]
  def all, do: Enum.map(index(), &elem(&1, 0))

  @doc "An entry by its `id` (`\"qmp:stop\"`), or nil; `extra` are more entries (the saved ones)."
  @spec get(String.t(), [map()]) :: map() | nil
  def get(id, extra \\ []) do
    Enum.find(extra, &(&1.id == id)) || Enum.find_value(index(), fn {e, _} -> e.id == id && e end)
  end

  @doc "The user's saved commands (`QemuAdmin.Terminal.Saved.load/0`) as entries of kind `\"saved\"`."
  @spec saved_entries([map()]) :: [map()]
  def saved_entries(commands) do
    for c <- commands do
      steps = c["steps"] || []

      %{
        id: "saved:#{c["name"]}",
        kind: "saved",
        name: c["name"],
        usage: "#{length(steps)} #{if length(steps) == 1, do: "passo", else: "passos"}",
        description: c["description"] || "",
        since: nil,
        args: [],
        emulators: [],
        steps: steps,
        vm: c["vm"],
        continue_on_error: c["continue_on_error"] == true
      }
    end
  end

  @doc """
  The entries whose kind is `kind` (`"all"`: any) and whose name or description
  contains `filter` (the table's filter bar: plain, case-insensitive substring).
  """
  @spec narrow([map()], String.t(), String.t()) :: [map()]
  def narrow(entries, kind, filter) do
    q = filter |> String.trim() |> normalize()

    Enum.filter(entries, fn e ->
      (kind in ["all", "", nil] or e.kind == kind) and
        (q == "" or String.contains?(normalize(e.name), q) or
           String.contains?(normalize(e.description), q))
    end)
  end

  @doc """
  The entries that have every word of `text`, best first: `{total, [entry]}`,
  cut at `limit` (40).
  """
  @spec search(String.t() | nil, keyword()) :: {non_neg_integer(), [map()]}
  def search(text, opts \\ []) do
    limit = Keyword.get(opts, :limit, @limit)
    extra = for e <- Keyword.get(opts, :extra, []), do: {e, postings(e)}

    case tokens(text) do
      [] ->
        {0, []}

      words ->
        wanted = normalize(text) |> String.trim()

        scored =
          for {entry, postings} <- extra ++ index(),
              scores = Enum.map(words, &word_score(postings, &1)),
              Enum.all?(scores, &(&1 > 0)) do
            bonus = if normalize(entry.name) == wanted, do: 100, else: 0
            {entry, Enum.sum(scores) + bonus}
          end

        docs =
          scored
          |> Enum.sort_by(fn {e, score} -> {-score, kind_rank(e.kind), e.name} end)
          |> Enum.take(limit)
          |> Enum.map(&elem(&1, 0))

        {length(scored), docs}
    end
  end

  @doc "Lower-case, no accents."
  def normalize(nil), do: ""

  def normalize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  @doc "The words of a text: letters and digits, normalised."
  def tokens(nil), do: []

  def tokens(text) do
    Regex.scan(~r/[a-z0-9]+/, normalize(text)) |> List.flatten() |> Enum.uniq()
  end

  # ---- the step an entry stands for ----------------------------------------------

  @doc """
  The line for `entry` with the values typed (`%{arg name => text}`); `nil` for an
  event, which is not a command. Empty values are left out; a QMP value is sent as
  the type says (`int`/`number` → number, `bool` → true/false, anything else a
  string, or JSON when it starts with `{`, `[` or a quote).
  """
  @spec line(map(), %{optional(String.t()) => String.t()}) :: String.t() | nil
  def line(%{kind: kind}, _values) when kind in ["event", "saved"], do: nil

  def line(%{kind: "qmp"} = e, values) do
    args =
      for a <- e.args, v = value(values, a.name), v != "", into: %{} do
        {a.name, qmp_value(a.type, v)}
      end

    if args == %{}, do: "qmp: #{e.name}", else: "qmp: #{e.name} #{Jason.encode!(args)}"
  end

  def line(%{kind: "hmp"} = e, values), do: join(["hmp:", e.name | typed(e, values)])
  def line(%{kind: "tool"} = e, values), do: join(["cli:", e.name | typed(e, values)])

  defp typed(e, values), do: for(a <- e.args, v = value(values, a.name), v != "", do: v)

  defp value(values, name), do: values |> Map.get(name, "") |> to_string() |> String.trim()

  defp join(parts), do: Enum.join(parts, " ")

  defp qmp_value(type, v) when type in ["int", "number", "size", "uint64", "uint32", "uint16", "uint8", "int64"] do
    case Integer.parse(v) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> v
        end
    end
  end

  defp qmp_value("bool", v), do: v in ["true", "on", "sim", "1"]

  defp qmp_value(_type, v) do
    if String.starts_with?(v, ["{", "[", "\""]) do
      case Jason.decode(v) do
        {:ok, term} -> term
        _ -> v
      end
    else
      v
    end
  end

  # ---- index ---------------------------------------------------------------------

  defp index do
    case :persistent_term.get(@key, nil) do
      nil ->
        built = build()
        :persistent_term.put(@key, built)
        built

      built ->
        built
    end
  end

  @doc false
  def build do
    path = Path.join([:code.priv_dir(:qemu_admin), "terminal", "commands.json"])

    raw =
      case File.read(path) do
        {:ok, bin} -> Jason.decode!(bin)
        _ -> %{}
      end

    entries =
      Enum.map(raw["hmp"] || [], &hmp/1) ++
        Enum.map(raw["qmp"] || [], &qmp/1) ++
        Enum.map(raw["qmp_events"] || [], &event/1) ++
        Enum.map(raw["tools"] || [], &tool/1)

    entries
    |> Enum.sort_by(&{kind_rank(&1.kind), &1.name})
    |> Enum.map(&{&1, postings(&1)})
  end

  defp base(kind, m, args) do
    %{
      id: "#{kind}:#{m["name"]}",
      kind: kind,
      name: m["name"],
      usage: m["usage"] || "",
      description: m["description"] || "",
      since: m["since"],
      args: args,
      emulators: m["emulators"] || []
    }
  end

  defp qmp(m), do: base("qmp", m, Enum.map(m["arguments"] || [], &arg/1))
  defp event(m), do: base("event", m, Enum.map(m["data"] || [], &arg/1))

  defp arg(a) do
    %{
      name: a["name"],
      type: a["type"] || "",
      required: a["required"] == true,
      description: a["description"] || ""
    }
  end

  defp hmp(m) do
    usage = m["usage"] || ""

    args =
      for tok <- String.split(usage), tok != "" do
        name = tok |> String.trim("[") |> String.trim("]") |> String.trim_leading("-")
        %{name: name, type: "", required: not String.starts_with?(tok, "["), description: ""}
      end

    base("hmp", m, args)
  end

  defp tool(m),
    do: base("tool", m, [%{name: "args", type: "", required: false, description: m["usage"] || ""}])

  # the tokens of an entry with the weight of the field they come from
  defp postings(e) do
    fields = [
      {e.name, 10},
      {Enum.map_join(e.args, " ", & &1.name), 5},
      {e.usage, 3},
      {e.description, 2},
      {Enum.join(Map.get(e, :steps, []), " "), 2},
      {Enum.map_join(e.args, " ", & &1.description), 1}
    ]

    Enum.reduce(fields, %{}, fn {text, weight}, acc ->
      Enum.reduce(tokens(text), acc, fn tok, acc -> Map.update(acc, tok, weight, &max(&1, weight)) end)
    end)
  end

  defp word_score(postings, word) do
    Enum.reduce(postings, 0, fn {tok, weight}, best ->
      cond do
        tok == word -> max(best, weight * 3)
        String.starts_with?(tok, word) -> max(best, weight)
        true -> best
      end
    end)
  end

  defp kind_rank(kind), do: Enum.find_index(@kinds, &(&1 == kind)) || 99
end
