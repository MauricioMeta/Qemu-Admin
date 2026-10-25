defmodule QemuAdmin.Gdb do
  @moduledoc """
  A minimal client of the GDB remote serial protocol, for QEMU's gdbstub
  (`QemuAdmin.Gpio` uses it to watch a board's GPIO registers).

  A connection is `%{socket:, buf:}`, passed along and returned. Commands
  are synchronous (`command/3`) on a passive socket; while the target runs,
  the owner puts the socket in `active: :once` and feeds what arrives to
  `take_packet/1` until the stop reply comes. "No ack" mode is asked for
  on connect; where the stub does not have it (Espressif's), every packet
  received is acked with `+` (`ack?`).
  """

  import Bitwise

  @timeout 5_000

  def connect(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, nodelay: true], 1_000) do
      {:ok, socket} ->
        conn = %{socket: socket, buf: "", ack?: true}

        case command(conn, "QStartNoAckMode") do
          {:ok, "OK", conn} -> {:ok, %{conn | ack?: false}}
          {:ok, "", conn} -> {:ok, conn}
          {:ok, other, _} -> {:error, "gdbstub: #{other}"}
          error -> error
        end

      error ->
        error
    end
  end

  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  @doc "Sends `packet` and waits for its reply."
  def command(conn, packet, timeout \\ @timeout) do
    with :ok <- send_packet(conn, packet), do: recv_packet(conn, timeout)
  end

  def send_packet(%{socket: socket}, packet), do: :gen_tcp.send(socket, encode(packet))

  @doc "Stops a running target (the reply is a stop packet)."
  def interrupt(%{socket: socket}), do: :gen_tcp.send(socket, <<3>>)

  def recv_packet(conn, timeout \\ @timeout) do
    case take_packet(conn) do
      {:ok, packet, conn} ->
        {:ok, packet, conn}

      {:more, conn} ->
        case :gen_tcp.recv(conn.socket, 0, timeout) do
          {:ok, data} -> recv_packet(%{conn | buf: conn.buf <> data}, timeout)
          error -> error
        end
    end
  end

  @doc """
  A whole packet off the front of the buffer: `{:ok, packet, conn}` or
  `{:more, conn}`. Acks and notifications are skipped.
  """
  def take_packet(%{buf: buf} = conn) do
    case :binary.match(buf, "$") do
      :nomatch ->
        {:more, %{conn | buf: ""}}

      {start, 1} ->
        rest = binary_part(buf, start + 1, byte_size(buf) - start - 1)

        case :binary.match(rest, "#") do
          {stop, 1} when byte_size(rest) >= stop + 3 ->
            packet = binary_part(rest, 0, stop)
            if conn.ack?, do: :gen_tcp.send(conn.socket, "+")

            {:ok, unescape(packet),
             %{conn | buf: binary_part(rest, stop + 3, byte_size(rest) - stop - 3)}}

          _ ->
            {:more, %{conn | buf: binary_part(buf, start, byte_size(buf) - start)}}
        end
    end
  end

  def encode(packet) do
    sum = packet |> :binary.bin_to_list() |> Enum.sum() |> band(0xFF)

    [
      "$",
      packet,
      "#",
      sum |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
    ]
  end

  defp unescape(packet) do
    if String.contains?(packet, "}"), do: unescape(packet, ""), else: packet
  end

  defp unescape(<<"}", c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, bxor(c, 0x20)>>)
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)
  defp unescape(<<>>, acc), do: acc

  # ------------------------------------------------------------- helpers

  @doc "Register `n` as an unsigned little-endian integer."
  def read_reg(conn, n) do
    case command(conn, "p" <> Integer.to_string(n, 16)) do
      {:ok, "E" <> _ = err, _} -> {:error, err}
      {:ok, hex, conn} -> {:ok, le(hex), conn}
      error -> error
    end
  end

  @doc "Writes register `n` (`bytes` wide, little-endian)."
  def write_reg(conn, n, value, bytes) do
    hex = <<value::little-size(bytes * 8)>> |> Base.encode16(case: :lower)

    case command(conn, "P#{Integer.to_string(n, 16)}=#{hex}") do
      {:ok, "OK", conn} -> {:ok, conn}
      {:ok, other, _} -> {:error, other}
      error -> error
    end
  end

  def read_mem(conn, addr, len) do
    case command(conn, "m#{Integer.to_string(addr, 16)},#{Integer.to_string(len, 16)}") do
      {:ok, "E" <> _ = err, _} -> {:error, err}
      {:ok, hex, conn} -> {:ok, Base.decode16!(hex, case: :mixed), conn}
      error -> error
    end
  end

  @doc "Every register (`g`), as the raw bytes."
  def read_regs(conn) do
    case command(conn, "g") do
      {:ok, "E" <> _ = err, _} -> {:error, err}
      {:ok, hex, conn} -> {:ok, Base.decode16!(hex, case: :mixed), conn}
      error -> error
    end
  end

  def le(hex), do: hex |> Base.decode16!(case: :mixed) |> :binary.decode_unsigned(:little)

  @doc ~S|The fields of a stop reply: "T05thread:01;watch:3ff44004;" → %{signal: 5, "thread" => "01", ...}|
  def stop_info("T" <> <<sig::binary-size(2), rest::binary>>) do
    rest
    |> String.split(";", trim: true)
    |> Enum.reduce(%{signal: String.to_integer(sig, 16)}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  def stop_info("S" <> <<sig::binary-size(2), _::binary>>),
    do: %{signal: String.to_integer(sig, 16)}

  def stop_info(other), do: %{signal: nil, raw: other}

  @doc "Whether the stop was one of our watchpoints."
  def watch?(info), do: Enum.any?(~w(watch rwatch awatch), &Map.has_key?(info, &1))
end
