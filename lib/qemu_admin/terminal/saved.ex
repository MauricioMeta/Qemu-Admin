defmodule QemuAdmin.Terminal.Saved do
  @moduledoc """
  The Terminal's **saved commands**: a name that runs a whole sequence of
  commands on the VM selected, kept in `terminal.json` at the root of the
  workspace (`path/0`). The file is meant to be edited by hand as well as from
  the page, and is read each time it is needed.

      {
        "version": 1,
        "commands": [
          {
            "name": "start",
            "description": "Liga a VM e mostra o estado",
            "vm": null,
            "steps": ["@start", "info status"],
            "continue_on_error": false
          }
        ]
      }

    * `name` — one word (letters, digits, `.`, `_`, `-`) that is typed in the
      Terminal to run it; a saved name comes before a monitor command of the
      same name;
    * `vm` — the id of the only VM the command exists for, or `null` for every VM;
    * `steps` — what to run, in order, each one as it would be typed in the
      Terminal (a QEMU tool, a monitor command, a QMP message), plus two of the
      app's own: `@start` (turns the VM on and waits until it runs) and
      `@wait N` (N seconds). A step says how it reaches QEMU with a prefix:
      `qmp: stop` (a QMP command, with arguments as JSON — `qmp: block_resize
      {"device": "d0", "size": 1048576}` — or a whole message), `hmp: info status`
      (the monitor) or `cli: qemu-img info {dir}/disk0.qcow2` (a QEMU tool, a
      process); with no prefix the Terminal tells by itself. `{vm}`, `{name}` and
      `{dir}` in a step are the VM's id, name and folder. Blank lines and lines
      starting with `#` are ignored;
    * `continue_on_error` — keep going when a step fails (it stops by default).

  See `QemuAdmin.Terminal.Macro` for how it runs.
  """

  alias QemuAdmin.{Paths, Terminal}

  @file_name "terminal.json"
  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/

  @doc "Where the saved commands are: `terminal.json` in the workspace."
  def path, do: Path.join(Paths.workspace_dir(), @file_name)

  @doc """
  Every command in the file: `{:ok, commands}` (none when there is no file) or
  `{:error, message}` when it cannot be read.
  """
  def load do
    case File.read(path()) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "#{path()}: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  def parse(text) do
    case Jason.decode(text) do
      {:ok, %{"commands" => list}} when is_list(list) ->
        {:ok, list |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

      {:ok, list} when is_list(list) ->
        {:ok, list |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

      {:ok, _} ->
        {:error, ~s(terminal.json: esperado {"commands": [...]})}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "terminal.json não é um JSON válido: #{Exception.message(e)}"}
    end
  end

  # what the file may hold, as the map the rest of the app uses; nil for what is not a command
  defp normalize(%{"name" => name, "steps" => steps} = c) when is_binary(name) and is_list(steps) do
    %{
      "name" => String.trim(name),
      "description" => if(is_binary(c["description"]), do: c["description"], else: ""),
      "vm" => if(is_binary(c["vm"]) and c["vm"] != "", do: c["vm"], else: nil),
      "steps" => clean_steps(steps),
      "continue_on_error" => c["continue_on_error"] == true
    }
  end

  defp normalize(_), do: nil

  @doc "Steps without the blank lines and the comments."
  def clean_steps(steps) do
    steps
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc "The commands the VM `vm_id` has: those for every VM and those for it only, by name."
  def list(vm_id) do
    case load() do
      {:ok, commands} ->
        commands
        |> Enum.filter(&(&1["vm"] in [nil, vm_id]))
        |> Enum.sort_by(&String.downcase(&1["name"]))

      {:error, _} ->
        []
    end
  end

  @doc "The command `input` names (the whole input, in any case) for `vm_id`: `{:ok, command}` or `:error`."
  def find(input, vm_id) do
    name = input |> String.trim() |> String.downcase()

    case Enum.find(list(vm_id), &(String.downcase(&1["name"]) == name)) do
      nil -> :error
      command -> {:ok, command}
    end
  end

  @doc """
  What a command from the form or the file must be: `{:ok, command}` normalized,
  or `{:error, message}`. `steps` may be a string with one step per line.
  """
  def validate(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    steps = attrs |> Map.get("steps", []) |> steps_list() |> clean_steps()
    vm = attrs |> Map.get("vm") |> then(&if(is_binary(&1) and &1 != "", do: &1))

    cond do
      not Regex.match?(@name_re, name) ->
        {:error, "o nome deve ser uma palavra só: letras, números, ponto, _ ou - (até 40 caracteres)"}

      steps == [] ->
        {:error, "dê pelo menos um passo"}

      bad = Enum.find_value(steps, &step_error/1) ->
        {:error, bad}

      true ->
        {:ok,
         %{
           "name" => name,
           "description" => attrs |> Map.get("description", "") |> to_string() |> String.trim(),
           "vm" => vm,
           "steps" => steps,
           "continue_on_error" => Map.get(attrs, "continue_on_error") in [true, "true", "on"]
         }}
    end
  end

  defp steps_list(text) when is_binary(text), do: String.split(text, ~r/\R/)
  defp steps_list(list) when is_list(list), do: list
  defp steps_list(_), do: []

  # why a step cannot run, or nil. `@start` and `@wait N` are the only steps the
  # app has of its own; `qmp:`, `hmp:` and `cli:` say how a line goes to QEMU
  defp step_error("@start"), do: nil

  defp step_error("@wait " <> n = step) do
    if match?({_, ""}, Integer.parse(String.trim(n))),
      do: nil,
      else: "passo inválido: #{step} (@wait espera um número de segundos)"
  end

  defp step_error("@" <> _ = step), do: "passo inválido: #{step} (só existem @start e @wait N)"

  defp step_error("qmp:" <> rest = step) do
    case Terminal.qmp_message(rest) do
      {:ok, _json} -> nil
      {:error, msg} -> "passo inválido: #{step} (#{msg})"
    end
  end

  defp step_error("hmp:" <> rest = step) do
    if String.trim(rest) == "", do: "passo inválido: #{step} (hmp: espera um comando do monitor)"
  end

  defp step_error("cli:" <> rest = step) do
    case Terminal.route(String.trim(rest)) do
      {:tool, _} -> nil
      {:error, msg} -> "passo inválido: #{step} (#{msg})"
      :monitor -> "passo inválido: #{step} (cli: só roda as ferramentas do QEMU: qemu-img, qemu-io, qemu-system-*)"
    end
  end

  defp step_error(_step), do: nil

  @doc """
  Saves `command` (`validate/1` already applied). `original` is the name it had
  when it is an edit (the command is replaced, even if renamed); `nil` for a
  new one. A name another command has is refused.
  """
  def save(command, original \\ nil) do
    with {:ok, commands} <- load_for_write() do
      clash = Enum.find(commands, &same?(&1["name"], command["name"]))
      edit_of_itself? = original != nil and same?(original, command["name"])

      if clash && not edit_of_itself? do
        {:error, "já existe um comando salvo chamado #{command["name"]}"}
      else
        keep =
          Enum.reject(commands, fn c ->
            same?(c["name"], command["name"]) or (original != nil and same?(c["name"], original))
          end)

        write(keep ++ [command])
      end
    end
  end

  @doc "Takes the command called `name` out of the file."
  def delete(name) do
    with {:ok, commands} <- load_for_write(),
         do: write(Enum.reject(commands, &same?(&1["name"], name)))
  end

  # a file that cannot be read is not overwritten
  defp load_for_write do
    case load() do
      {:error, msg} -> {:error, msg <> " — corrija ou apague o arquivo antes de salvar daqui"}
      ok -> ok
    end
  end

  defp same?(a, b), do: String.downcase(a) == String.downcase(b)

  defp write(commands) do
    sorted = Enum.sort_by(commands, &String.downcase(&1["name"]))
    # the keys in the order a person reads them
    ordered =
      Enum.map(sorted, fn c ->
        Jason.OrderedObject.new([
          {"name", c["name"]},
          {"description", c["description"]},
          {"vm", c["vm"]},
          {"steps", c["steps"]},
          {"continue_on_error", c["continue_on_error"]}
        ])
      end)

    json =
      Jason.encode!(Jason.OrderedObject.new([{"version", 1}, {"commands", ordered}]), pretty: true)
    path = path()
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, json <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end
end
