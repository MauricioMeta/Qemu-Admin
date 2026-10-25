defmodule QemuAdmin.Settings do
  @moduledoc """
  The user's preferences, kept in `settings.json` in the data directory
  (`QemuAdmin.Paths.settings_file/0`).

  `schema/0` is the one list of what can be configured — type, default,
  label and the choices of a select — and the Configurações page is drawn
  from it (but for the `hidden` entries, kept by the app itself). Values are cast against it on the way in, so a hand-edited file
  with a bad value falls back to the default instead of crashing.

  An Agent holds the current values; outside the application (a Mix task)
  `get/1` reads the file directly.
  """

  use Agent

  alias QemuAdmin.Paths

  @schema [
    %{
      key: :qemu_dir,
      section: :qemu,
      type: :string,
      default: "",
      label: "Pasta do QEMU",
      help:
        "Vazio: o QEMU embutido no app, depois o baixado em Configurações › QEMU, depois o PATH."
    },
    %{
      key: :default_accel,
      section: :qemu,
      type: :select,
      default: "auto",
      label: "Aceleração padrão",
      choices: [
        {"auto", "Automática (WHPX/KVM/HVF, senão TCG)"},
        {"tcg", "TCG (emulação, sempre funciona)"},
        {"whpx", "WHPX (Windows Hypervisor Platform)"},
        {"kvm", "KVM (Linux)"},
        {"hvf", "HVF (macOS)"}
      ],
      help: "Usada pelas VMs novas."
    },
    %{
      key: :default_display,
      section: :qemu,
      type: :select,
      default: "vnc",
      label: "Tela padrão",
      choices: [
        {"vnc", "Console no app (VNC)"},
        {"sdl", "Janela SDL"},
        {"gtk", "Janela GTK"},
        {"none", "Sem tela (headless)"}
      ],
      help: "Usada pelas VMs novas."
    },
    %{
      key: :workspace,
      section: :storage,
      type: :string,
      default: "",
      label: "Workspace",
      help:
        "A pasta com as VMs (vms/) e as imagens (images/). Vazio: a pasta de dados. Troque pela lista de VMs."
    },
    %{
      key: :recent_workspaces,
      section: :storage,
      type: :list,
      default: [],
      hidden: true,
      label: "Workspaces recentes"
    },
    %{
      key: :confirm_close,
      section: :general,
      type: :boolean,
      default: true,
      label: "Confirmar ao fechar com VMs ligadas",
      help: "Fechar o app desliga as VMs em execução."
    },
    %{
      key: :stop_timeout,
      section: :general,
      type: :integer,
      default: 30,
      min: 0,
      max: 600,
      label: "Espera do desligamento (s)",
      help:
        "Ao fechar o app: quanto esperar o sistema convidado desligar (ACPI) antes de encerrar o QEMU."
    }
  ]

  @doc "Everything configurable, in page order."
  def schema, do: @schema

  @doc "The schema entries of one section of the page."
  def section(section),
    do: Enum.filter(@schema, &(&1.section == section and not Map.get(&1, :hidden, false)))

  def defaults, do: Map.new(@schema, &{&1.key, &1.default})

  def start_link(_opts) do
    Agent.start_link(fn -> load() end, name: __MODULE__)
  end

  @doc "Every setting."
  def all do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: load()
  end

  def get(key), do: Map.get(all(), key)

  @doc """
  Merges `params` (string or atom keys, as a form sends them) into the
  settings, casts them and saves the file. Unknown keys are ignored.
  """
  def put(params) when is_map(params), do: replace(cast(Map.merge(all(), atomize(params))))

  @doc "Back to the defaults."
  def reset, do: replace(defaults())

  defp replace(new) do
    save(new)
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> new end)
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, "settings", {:settings, new})
    new
  end

  defp load do
    case File.read(Paths.settings_file()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> cast(Map.merge(defaults(), atomize(map)))
          _ -> defaults()
        end

      _ ->
        defaults()
    end
  end

  defp save(settings) do
    File.mkdir_p!(Path.dirname(Paths.settings_file()))
    File.write!(Paths.settings_file(), Jason.encode_to_iodata!(settings, pretty: true))
  end

  defp atomize(map) do
    keys = Map.new(@schema, &{to_string(&1.key), &1.key})

    for {k, v} <- map, key = (is_atom(k) && k) || keys[k], key in Map.values(keys), into: %{} do
      {key, v}
    end
  end

  @doc false
  def cast(settings) do
    Map.new(@schema, fn entry ->
      {entry.key, cast_value(entry, Map.get(settings, entry.key))}
    end)
  end

  defp cast_value(%{type: :string, default: d}, v),
    do: if(is_binary(v), do: String.trim(v), else: d)

  defp cast_value(%{type: :list, default: d}, v) do
    if is_list(v), do: Enum.filter(v, &is_binary/1), else: d
  end

  defp cast_value(%{type: :boolean, default: d}, v) do
    case v do
      b when is_boolean(b) -> b
      "true" -> true
      "on" -> true
      "false" -> false
      _ -> d
    end
  end

  defp cast_value(%{type: :integer, default: d} = e, v) do
    n =
      case v do
        n when is_integer(n) ->
          n

        s when is_binary(s) ->
          with({n, ""} <- Integer.parse(String.trim(s)), do: n, else: (_ -> d))

        _ ->
          d
      end

    n |> max(Map.get(e, :min, n)) |> min(Map.get(e, :max, n))
  end

  defp cast_value(%{type: :select, default: d, choices: choices}, v) do
    if Enum.any?(choices, fn {value, _} -> value == v end), do: v, else: d
  end
end
