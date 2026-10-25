defmodule QemuAdmin.Raspi.Image do
  @moduledoc """
  A Raspberry Pi OS image (or any SD card image with the Pi's boot
  partition) made into a VM's SD card: copied into its folder as `sd.img`
  (`.xz`, `.zip` and `.7z` unpacked with 7-Zip), grown to a power of two
  (QEMU's SD card only takes those sizes, and the system grows its root
  partition into the room on first boot), and the kernel, device tree and
  `cmdline.txt` taken from its boot partition (`QemuAdmin.Raspi.Fat`), since
  QEMU boots the kernel directly (`-kernel`, `-dtb`, `-append`): the Pi's
  own boot firmware is not emulated.

  The command line is the image's with the console on the PL011 UART (what
  QEMU wires to `-serial`: `ttyAMA1` or `ttyAMA0`, by board) and on the
  screen, and without the watchdog: systemd arms the BCM2835's and, under
  emulation, misses feeding it in time — the board resets in a loop.

  Raspberry Pi OS has no user until its first boot asks for one at the
  keyboard (a Pi 4 in QEMU has none: no USB). So, as Raspberry Pi Imager
  does, the import can write `userconf.txt` — the user and its password,
  hashed (`QemuAdmin.Raspi.Crypt`) — and `ssh` (enables the SSH server)
  into the boot partition (`opts`: `:user`, `:password`, `:ssh`).
  """

  import Bitwise

  alias QemuAdmin.Qemu.Installer
  alias QemuAdmin.Raspi.Fat

  @card "sd.img"

  def extensions, do: ~w(.img .xz .zip .7z)

  # what each kind of Pi boots when its own kernel is not on the card
  @kernels %{
    "kernel8.img" => ~w(kernel8.img kernel_2712.img),
    "kernel7.img" => ~w(kernel7.img kernel7l.img),
    "kernel.img" => ~w(kernel.img)
  }

  @doc """
  Imports `src` into `dir` for `board` (`QemuAdmin.Board`):
  `{:ok, %{disk:, kernel:, dtb:, append:}}`, file names inside `dir`.
  """
  def import(src, dir, board, opts \\ []) do
    File.mkdir_p!(dir)
    card = Path.join(dir, @card)

    with :ok <- copy(src, dir, card),
         {:ok, boot} <- boot_files(card, board),
         :ok <- first_boot(card, opts),
         :ok <- grow(card) do
      {:ok, Map.put(boot, :disk, @card)}
    end
  end

  @doc "Writes `userconf.txt` and `ssh` into the card's boot partition, as `opts` ask."
  def first_boot(card, opts) do
    user = String.trim(opts[:user] || "")

    files =
      if(user != "" and (opts[:password] || "") != "",
        do: [{"userconf.txt", "#{user}:#{QemuAdmin.Raspi.Crypt.sha512(opts[:password])}\n"}],
        else: []
      ) ++ if(opts[:ssh], do: [{"ssh", ""}], else: [])

    if files == [] do
      :ok
    else
      with {:ok, fat} <- Fat.open(card, :write) do
        try do
          Enum.reduce_while(files, :ok, fn {name, data}, :ok ->
            case Fat.create(fat, name, data) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        after
          Fat.close(fat)
        end
      end
    end
  end

  defp copy(src, dir, card) do
    case String.downcase(Path.extname(src)) do
      ext when ext in [".xz", ".zip", ".7z"] ->
        unpack(src, dir, card)

      _ ->
        with({:error, r} <- File.cp(src, card), do: {:error, "#{src}: #{:file.format_error(r)}"})
    end
  end

  defp unpack(src, dir, card) do
    case Installer.seven_zip() do
      nil ->
        {:error,
         "descompacte a imagem antes (o 7-Zip não foi encontrado para abrir #{Path.extname(src)})"}

      exe ->
        tmp = Path.join(dir, "sd.tmp")
        File.rm_rf!(tmp)

        case System.cmd(exe, ["x", "-y", "-o" <> tmp, src], stderr_to_stdout: true) do
          {_, 0} ->
            image =
              tmp
              |> Path.join("**/*")
              |> Path.wildcard()
              |> Enum.filter(&File.regular?/1)
              |> Enum.max_by(&File.stat!(&1).size, fn -> nil end)

            result =
              if image,
                do: File.rename(image, card),
                else: {:error, "nada dentro de #{Path.basename(src)}"}

            File.rm_rf!(tmp)
            result

          {out, _} ->
            File.rm_rf!(tmp)
            {:error, "7-Zip: #{out |> String.split("\n") |> Enum.take(-3) |> Enum.join(" ")}"}
        end
    end
  end

  @doc "Copies the kernel and device tree out of the card's boot partition, next to it."
  def boot_files(card, board) do
    dir = Path.dirname(card)

    with {:ok, fat} <- Fat.open(card) do
      try do
        {:ok, files} = Fat.list(fat)
        names = Enum.map(files, & &1.name)

        with {:ok, kernel} <- pick(names, @kernels[board.kernel], "kernel"),
             {:ok, dtb} <- pick(names, [board.dtb], "device tree #{board.dtb}"),
             :ok <- extract(fat, kernel, dir),
             :ok <- extract(fat, dtb, dir) do
          cmdline =
            case Fat.read(fat, "cmdline.txt") do
              {:ok, text} -> text
              _ -> ""
            end

          {:ok, %{kernel: kernel, dtb: dtb, append: append(cmdline, board.uart)}}
        end
      after
        Fat.close(fat)
      end
    end
  end

  defp pick(names, wanted, what) do
    case Enum.find(wanted, fn w -> Enum.any?(names, &(String.downcase(&1) == w)) end) do
      nil -> {:error, "a partição de boot não tem o #{what}"}
      name -> {:ok, name}
    end
  end

  defp extract(fat, name, dir) do
    with {:ok, data} <- Fat.read(fat, name), do: File.write(Path.join(dir, name), data)
  end

  @doc """
  The kernel command line for QEMU from the image's `cmdline.txt`: its
  consoles replaced by the screen and `uart` (last, so /dev/console: the
  boot status and a login there); the rest (root partition,
  first-boot resize) kept.
  """
  def append(cmdline, uart \\ "ttyAMA1") do
    rest =
      cmdline
      |> String.split()
      |> Enum.reject(&String.starts_with?(&1, "console="))

    rest =
      if Enum.any?(rest, &String.starts_with?(&1, "root=")),
        do: rest,
        else: rest ++ ~w(root=/dev/mmcblk0p2 rootfstype=ext4 rootwait)

    Enum.join(
      # the last console is /dev/console: the UART gets the boot status and a login
      ["console=tty1", "console=#{uart},115200"] ++
        rest ++ ~w(dwc_otg.fiq_fsm_enable=0 systemd.watchdog_sec=0 modprobe.blacklist=bcm2835_wdt),
      " "
    )
  end

  @doc "Grows the card to the next power of two (at least 4 GiB)."
  def grow(card) do
    size = File.stat!(card).size
    target = Enum.find(32..40, &(1 <<< &1 >= size)) |> then(&max(1 <<< &1, 1 <<< 32))

    if target == size do
      :ok
    else
      with {:ok, io} <- :file.open(card, [:read, :write, :binary, :raw]),
           {:ok, _} <- :file.position(io, target),
           :ok <- :file.truncate(io) do
        :file.close(io)
      end
    end
  end
end
