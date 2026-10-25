defmodule QemuAdminWeb.Files do
  @moduledoc """
  Lists a folder for the file picker (`Components.Files.Picker`): folders
  first, then the files with one of `exts`, each `%{name:, path:, dir?:,
  size:}`. The empty path is the top: the drives on Windows, `/` elsewhere.
  Hidden entries (dot files) are left out.
  """

  def list("", exts) do
    case :os.type() do
      {:win32, _} ->
        drives =
          for letter <- ?A..?Z,
              root = <<letter, ":/">>,
              File.dir?(root) do
            %{name: <<letter, ":">>, path: root, dir?: true, size: nil}
          end

        {:ok, drives}

      _ ->
        list("/", exts)
    end
  end

  def list(dir, exts) do
    exts = Enum.map(exts, &String.downcase/1)

    case File.ls(dir) do
      {:ok, names} ->
        entries =
          names
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.flat_map(fn name ->
            path = Path.join(dir, name)

            case File.stat(path) do
              {:ok, %{type: :directory}} ->
                [%{name: name, path: path, dir?: true, size: nil}]

              {:ok, %{type: :regular, size: size}} ->
                if exts == [] or String.downcase(Path.extname(name)) in exts,
                  do: [%{name: name, path: path, dir?: false, size: size}],
                  else: []

              _ ->
                []
            end
          end)
          |> Enum.sort_by(&{not &1.dir?, String.downcase(&1.name)})

        {:ok, entries}

      {:error, reason} ->
        {:error, "#{dir}: #{:file.format_error(reason)}"}
    end
  end
end
