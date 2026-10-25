defmodule QemuAdmin.Session do
  @moduledoc """
  What the page had open, kept between visits, so a reload, a restart of the app
  or reopening the workspace brings back the tabs as they were left (the idea is
  Rockwell Viewer's `.workspace`).

  One JSON file, `session.json`, at the root of the workspace — beside
  `terminal.json` — so it follows the folder when it moves, and each workspace has
  its own:

      {
        "version": 1,
        "view": "vms",                      # the page: vms, disks, images, qemu, commands or settings
        "selected": "pi3",                  # the VM on screen
        "tabs": ["pi3", "netduino"],        # the open tabs, in order
        "views": {"pi3": "serial"},         # what each tab was showing
        "terminal_open": true               # the Terminal expanded or folded
      }

  This module only reads and writes; a VM that no longer exists or a view that
  is not there is for whoever restores to drop. The widths and heights the user
  dragged live in the browser (`localStorage`).
  """

  alias QemuAdmin.Paths

  @file_name "session.json"
  @pages ~w(vms disks images qemu commands settings)

  @doc "Where the session is: `session.json` in the workspace."
  def path, do: Path.join(Paths.workspace_dir(), @file_name)

  @doc "The stored session, cleaned: a map with every key (`view`, `selected`, `tabs`, `views`, `terminal_open`)."
  @spec load() :: map()
  def load do
    with {:ok, text} <- File.read(path()),
         {:ok, %{} = raw} <- Jason.decode(text) do
      clean(raw)
    else
      _ -> clean(%{})
    end
  end

  @doc "Stores the session (what `load/0` returns); `:ok` or `{:error, message}`."
  @spec save(map()) :: :ok | {:error, String.t()}
  def save(session) do
    json = session |> clean() |> encode()
    path = path()
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # the keys in the order a person reads them
  defp encode(s) do
    object =
      Jason.OrderedObject.new([
        {"version", 1},
        {"view", s["view"]},
        {"selected", s["selected"]},
        {"tabs", s["tabs"]},
        {"views", s["views"]},
        {"terminal_open", s["terminal_open"]}
      ])

    Jason.encode!(object, pretty: true) <> "\n"
  end

  defp clean(raw) do
    tabs = for t <- list(raw["tabs"]), is_binary(t), uniq: true, do: t
    views = if is_map(raw["views"]), do: for({k, v} <- raw["views"], is_binary(v), into: %{}, do: {k, v}), else: %{}

    %{
      "view" => if(raw["view"] in @pages, do: raw["view"], else: "vms"),
      "selected" => if(is_binary(raw["selected"]), do: raw["selected"]),
      "tabs" => tabs,
      "views" => views,
      "terminal_open" => raw["terminal_open"] != false
    }
  end

  defp list(l) when is_list(l), do: l
  defp list(_), do: []
end
