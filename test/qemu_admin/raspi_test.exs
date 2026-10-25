defmodule QemuAdmin.RaspiTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Board
  alias QemuAdmin.Raspi.{Crypt, Fat, Image}

  @moduletag :tmp_dir

  test "SHA-512 crypt matches glibc's (openssl passwd -6)" do
    assert Crypt.sha512("raspberry", "abcdefgh") ==
             "$6$abcdefgh$4o4.L3tiGL1RD7BsjaaWYcCVs87zOlvZK7S6SXQETuFMA2ELLDwmf3YDHidZ3I4E/fXmmOOWhAJHUSMf.eA6c1"

    assert Crypt.sha512("Hello world!", "saltstring") ==
             "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"

    assert "$6$" <> _ = Crypt.sha512("x")
  end

  # A disk with one FAT16 partition at sector 1: 512-byte sectors, one per
  # cluster, two FATs of 8 sectors, 64 root entries (4 sectors).
  defp fat16_image(path, files) do
    lba = 1
    bps = 512
    fat_sectors = 8
    root_sectors = 4
    data_lba = lba + 1 + 2 * fat_sectors + root_sectors

    mbr =
      <<0::size(446 * 8), 0, 0::24, 0x06, 0::24, lba::little-32, 2048::little-32, 0::size(48 * 8),
        0x55, 0xAA>>

    boot =
      <<0xEB, 0x3C, 0x90, "MSWIN4.1", bps::little-16, 1, 1::little-16, 2, 64::little-16,
        2048::little-16, 0xF8, fat_sectors::little-16, 0::size(bps * 8 - 24 * 8)>>

    {entries, fat, data} =
      files
      |> Enum.with_index(2)
      |> Enum.reduce({"", %{}, ""}, fn {{name, content}, cluster}, {e, f, d} ->
        [base, ext] = String.split(name, ".")

        short =
          String.pad_trailing(String.upcase(base), 8) <>
            String.pad_trailing(String.upcase(ext), 3)

        entry =
          <<short::binary, 0x20, 0::size(8 * 8), 0::16, 0::32, cluster::little-16,
            byte_size(content)::little-32>>

        {e <> entry, Map.put(f, cluster, 0xFFFF), d <> String.pad_trailing(content, bps, <<0>>)}
      end)

    fat_table =
      Enum.reduce(0..(fat_sectors * 256 - 1), "", fn i, acc ->
        v = if i < 2, do: 0xFFF8, else: Map.get(fat, i, 0)
        acc <> <<v::little-16>>
      end)

    root = String.pad_trailing(entries, root_sectors * bps, <<0>>)
    image = mbr <> boot <> fat_table <> fat_table <> root <> data
    File.write!(path, String.pad_trailing(image, (data_lba + 64) * bps, <<0>>))
  end

  test "reads the root files of the boot partition", %{tmp_dir: dir} do
    card = Path.join(dir, "sd.img")

    fat16_image(card, [
      {"kernel8.img", "KERNEL"},
      {"cmdline.txt", "console=serial0 root=/dev/x\n"}
    ])

    {:ok, fat} = Fat.open(card)
    assert {:ok, files} = Fat.list(fat)
    assert Enum.map(files, & &1.name) == ["KERNEL8.IMG", "CMDLINE.TXT"]
    assert Fat.read(fat, "kernel8.img") == {:ok, "KERNEL"}
    assert {:error, :enoent} = Fat.read(fat, "nada.txt")
    Fat.close(fat)
  end

  test "creates userconf.txt and ssh for the first boot", %{tmp_dir: dir} do
    card = Path.join(dir, "sd.img")
    fat16_image(card, [{"kernel8.img", "KERNEL"}])

    assert :ok = Image.first_boot(card, user: "pi", password: "raspberry", ssh: true)

    {:ok, fat} = Fat.open(card)
    assert {:ok, "pi:$6$" <> _} = Fat.read(fat, "userconf.txt")
    assert {:ok, ""} = Fat.read(fat, "ssh")
    assert Fat.read(fat, "kernel8.img") == {:ok, "KERNEL"}
    Fat.close(fat)

    # a second time: the file is there already
    assert {:error, _} = Image.first_boot(card, user: "pi", password: "x")
  end

  test "takes the kernel and device tree for the board", %{tmp_dir: dir} do
    card = Path.join(dir, "sd.img")
    board = Board.get("raspi3b")

    fat16_image(card, [
      {"kernel8.img", "K8"},
      {"bcm2710-rpi-3-b.dtb", "DTB"},
      {"cmdline.txt", "console=serial0,115200 root=PARTUUID=ab-02 rootwait\n"}
    ])

    # the 8.3 test image cannot hold the dtb's long name: it fails on it
    assert {:error, "a partição de boot não tem o device tree " <> _} =
             Image.boot_files(card, board)

    fat16_image(card, [{"kernel8.img", "K8"}])
    assert {:error, _} = Image.boot_files(card, board)
  end

  test "grows the card to a power of two, at least 4 GiB", %{tmp_dir: dir} do
    card = Path.join(dir, "sd.img")
    File.write!(card, "x")
    assert :ok = Image.grow(card)
    assert File.stat!(card).size == 4_294_967_296
    File.rm!(card)
  end
end
