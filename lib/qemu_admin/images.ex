defmodule QemuAdmin.Images do
  @moduledoc """
  The workspace's image library (`QemuAdmin.Paths.images_dir/0`): what is
  in it (`list/0`, each file with its kind) and a small catalog of images
  to download into it (`catalog/0`, `download/1`) — the newest release of
  each, resolved when asked and checked against its SHA-256.

  One download at a time, in a process of its own: its progress goes out
  on the `"images"` topic as `{:image_download, state}` and stays here for a
  page opened halfway (`state/0`); `state` is `%{id:, phase:, received:,
  total:, error:, file:}`, `phase` one of `:idle`, `:resolve`, `:download`,
  `:verify`, `:done`, `:error`.
  """

  use GenServer

  alias QemuAdmin.Paths
  alias QemuAdmin.Qemu.Installer

  @kinds [
    {~w(.iso), :iso, "ISO (CD/DVD)"},
    {~w(.qcow2 .vmdk .vdi .vhdx .raw), :disk, "Disco de VM"},
    {~w(.img .xz .zip .7z), :sd, "Imagem de disco / cartão SD"},
    {~w(.hex .elf), :avr, "Firmware de Arduino"},
    {~w(.avm), :avm, "App AtomVM"},
    {~w(.bin), :bin, "Binário (flash)"}
  ]

  @doc "The extensions the library lists."
  def extensions, do: Enum.flat_map(@kinds, &elem(&1, 0))

  @doc "`{kind, label}` of a file, by its extension."
  def kind(path) do
    ext = path |> Path.extname() |> String.downcase()

    Enum.find_value(@kinds, {:other, "Arquivo"}, fn {exts, k, l} -> if ext in exts, do: {k, l} end)
  end

  @doc "The library's files: `[%{path:, name:, size:, kind:, kind_label:}]`, by name."
  def list do
    dir = Paths.images_dir()
    File.mkdir_p(dir)

    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and String.downcase(Path.extname(&1)) in extensions()))
    |> Enum.map(fn path ->
      {kind, label} = kind(path)

      %{
        path: path,
        name: Path.basename(path),
        size: File.stat!(path).size,
        kind: kind,
        kind_label: label
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  # ------------------------------------------------------------ catalog

  @catalog [
    %{
      id: "raspios-lite-arm64",
      name: "Raspberry Pi OS Lite (64-bit)",
      desc: "Sem desktop. Para Raspberry Pi 3 e 4.",
      for: "Raspberry Pi",
      latest: "https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
    },
    %{
      id: "raspios-lite-armhf",
      name: "Raspberry Pi OS Lite (32-bit)",
      desc: "Sem desktop. Para Raspberry Pi 2 e Zero.",
      for: "Raspberry Pi",
      latest: "https://downloads.raspberrypi.com/raspios_lite_armhf_latest"
    },
    %{
      id: "alpine-virt-x86_64",
      name: "Alpine Linux virt (x86_64)",
      desc: "Linux mínimo (~70 MB) para VMs de PC.",
      for: "PC",
      alpine: "x86_64"
    },
    %{
      id: "alpine-virt-aarch64",
      name: "Alpine Linux virt (aarch64)",
      desc: "Linux mínimo para VMs ARM (virt, UEFI).",
      for: "PC ARM",
      alpine: "aarch64"
    }
  ]

  def catalog, do: @catalog

  @doc "Where an entry's newest release is: `{:ok, %{url:, file:, sha256:}}`."
  def resolve(%{latest: url}) do
    # the "latest" link redirects to the dated file; its checksum sits beside it
    with {:ok, %{status: s} = resp} when s in 301..308 <-
           Req.head(url, redirect: false, retry: false),
         [target | _] <- Req.Response.get_header(resp, "location"),
         {:ok, %{status: 200, body: body}} <- Req.get(target <> ".sha256", retry: :transient),
         [sha | _] <- String.split(to_string(body)) do
      {:ok,
       %{url: target, file: Path.basename(URI.parse(target).path), sha256: String.downcase(sha)}}
    else
      {:ok, %{status: s}} -> {:error, "#{url} respondeu #{s}"}
      {:error, e} -> {:error, Exception.message(e)}
      _ -> {:error, "não foi possível achar a versão mais nova de #{url}"}
    end
  end

  def resolve(%{alpine: arch}) do
    base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/#{arch}/"

    with {:ok, %{status: 200, body: body}} <-
           Req.get(base <> "latest-releases.yaml", retry: :transient),
         [_, entry | _] <- String.split(to_string(body), ~r/flavor: alpine-virt\b/),
         [_, file] <- Regex.run(~r/\n\s*iso: (\S+)/, entry),
         [_, sha] <- Regex.run(~r/\n\s*sha256: ([0-9a-fA-F]+)/, entry) do
      {:ok, %{url: base <> file, file: file, sha256: String.downcase(sha)}}
    else
      {:ok, %{status: s}} -> {:error, "Alpine respondeu #{s}"}
      {:error, e} -> {:error, Exception.message(e)}
      _ -> {:error, "a lista de versões do Alpine mudou de formato"}
    end
  end

  # --------------------------------------------------------- download job

  @idle %{id: nil, phase: :idle, received: 0, total: nil, error: nil, file: nil}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Downloads catalog entry `id` into the library, unless a download is running."
  def download(id), do: GenServer.call(__MODULE__, {:download, id})

  @impl true
  def init(:ok), do: {:ok, %{job: @idle, task: nil}}

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.job, s}

  def handle_call({:download, _}, _from, %{task: t} = s) when t != nil,
    do: {:reply, {:error, "já há um download em andamento"}, s}

  def handle_call({:download, id}, _from, s) do
    case Enum.find(@catalog, &(&1.id == id)) do
      nil ->
        {:reply, {:error, "imagem desconhecida"}, s}

      entry ->
        me = self()
        dir = Paths.images_dir()

        task =
          Task.async(fn ->
            with {:ok, rel} <- resolve(entry) do
              send(me, {:progress, {:file, rel.file}})
              path = Path.join(dir, rel.file)
              File.mkdir_p!(dir)

              if File.regular?(path) and sha256(path) == rel.sha256 do
                {:ok, path}
              else
                with :ok <- Installer.download(rel.url, path, &send(me, {:progress, &1})),
                     _ = send(me, {:progress, {:verify, nil}}),
                     true <- sha256(path) == rel.sha256 || {:error, "SHA-256 não confere"} do
                  {:ok, path}
                else
                  error ->
                    File.rm(path)
                    error
                end
              end
            end
          end)

        {:reply, :ok, update(%{s | task: task}, %{@idle | id: id, phase: :resolve})}
    end
  end

  @impl true
  def handle_info({:progress, {:file, file}}, s), do: {:noreply, update(s, %{s.job | file: file})}

  def handle_info({:progress, {:download, {received, total}}}, s) do
    if s.job.phase != :download or received - s.job.received > 4_194_304 or received == total,
      do: {:noreply, update(s, %{s.job | phase: :download, received: received, total: total})},
      else: {:noreply, s}
  end

  def handle_info({:progress, {:verify, _}}, s),
    do: {:noreply, update(s, %{s.job | phase: :verify})}

  def handle_info({:progress, _}, s), do: {:noreply, s}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])

    job =
      case result do
        {:ok, _path} -> %{s.job | phase: :done}
        {:error, reason} -> %{s.job | phase: :error, error: to_string(reason)}
      end

    {:noreply, update(%{s | task: nil}, job)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = s),
    do: {:noreply, update(%{s | task: nil}, %{s.job | phase: :error, error: inspect(reason)})}

  def handle_info(_msg, s), do: {:noreply, s}

  defp sha256(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp update(s, job) do
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, "images", {:image_download, job})
    %{s | job: job}
  end
end
