defmodule QemuAdmin.Raspi.Crypt do
  @moduledoc """
  SHA-512 crypt (`$6$`, Ulrich Drepper's scheme, the one glibc's `crypt(3)`
  and `openssl passwd -6` produce): the password hash a Raspberry Pi OS
  `userconf.txt` carries (`QemuAdmin.Raspi.Image`).
  """

  import Bitwise

  @rounds 5_000
  @alphabet ~c"./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # how the 64 bytes of the digest are taken, three at a time
  @groups [
    {0, 21, 42},
    {22, 43, 1},
    {44, 2, 23},
    {3, 24, 45},
    {25, 46, 4},
    {47, 5, 26},
    {6, 27, 48},
    {28, 49, 7},
    {50, 8, 29},
    {9, 30, 51},
    {31, 52, 10},
    {53, 11, 32},
    {12, 33, 54},
    {34, 55, 13},
    {56, 14, 35},
    {15, 36, 57},
    {37, 58, 16},
    {59, 17, 38},
    {18, 39, 60},
    {40, 61, 19},
    {62, 20, 41}
  ]

  @doc "`$6$salt$hash` of `password`; a random salt when none is given."
  def sha512(password, salt \\ random_salt()) do
    salt = binary_part(salt, 0, min(byte_size(salt), 16))
    len = byte_size(password)

    b = hash([password, salt, password])

    a =
      hash([
        password,
        salt,
        repeat(b, len),
        for(bit <- bits(len), do: if(bit == 1, do: b, else: password))
      ])

    p = password |> List.duplicate(len) |> hash() |> repeat(len)
    s = salt |> List.duplicate(16 + :binary.first(a)) |> hash() |> repeat(byte_size(salt))

    c =
      Enum.reduce(0..(@rounds - 1), a, fn i, c ->
        hash([
          if(odd?(i), do: p, else: c),
          if(rem(i, 3) != 0, do: s, else: ""),
          if(rem(i, 7) != 0, do: p, else: ""),
          if(odd?(i), do: c, else: p)
        ])
      end)

    "$6$" <> salt <> "$" <> encode(c)
  end

  defp hash(data), do: :crypto.hash(:sha512, data)

  defp odd?(i), do: rem(i, 2) == 1

  # `digest` repeated (and cut) to `len` bytes
  defp repeat(digest, len) do
    digest |> :binary.copy(div(len, 64) + 1) |> binary_part(0, len)
  end

  # the length's bits, least significant first, up to the highest set one
  defp bits(0), do: []
  defp bits(n), do: [n &&& 1 | bits(n >>> 1)]

  defp encode(c) do
    byte = fn i -> :binary.at(c, i) end

    groups =
      Enum.map(@groups, fn {x, y, z} ->
        b64(byte.(x) <<< 16 ||| byte.(y) <<< 8 ||| byte.(z), 4)
      end)

    IO.iodata_to_binary([groups, b64(byte.(63), 2)])
  end

  defp b64(_w, 0), do: []
  defp b64(w, n), do: [Enum.at(@alphabet, w &&& 0x3F) | b64(w >>> 6, n - 1)]

  defp random_salt do
    for <<b <- :crypto.strong_rand_bytes(16)>>, into: "", do: <<Enum.at(@alphabet, b &&& 0x3F)>>
  end
end
