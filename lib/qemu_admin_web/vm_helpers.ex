defmodule QemuAdminWeb.VmHelpers do
  @moduledoc """
  Small things the VM pages share: the screenshot's URL, what a runtime
  allows (start? stop?), durations and the label of an accelerator.
  """

  alias QemuAdmin.{Paths, Vm}

  @doc "The screenshot URL (cache-busted by its revision), or nil when there is none."
  def screen_url(%Vm{id: id}, rt) do
    rev = Map.get(rt, :screen_rev, 0)

    cond do
      rev > 0 -> "/vms/#{id}/screen.png?v=#{rev}"
      File.regular?(Path.join(Paths.vm_dir(id), "screen.png")) -> "/vms/#{id}/screen.png?v=0"
      true -> nil
    end
  end

  def running?(%{status: s}), do: s in [:running, :paused, :starting, :stopping]
  def stopped?(%{status: s}), do: s == :stopped
  def paused?(%{status: s}), do: s == :paused

  @doc "Time since `started_at`, as 1h 02m / 3m 05s."
  def uptime(%{started_at: %DateTime{} = t}) do
    s = DateTime.diff(DateTime.utc_now(), t)
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)

    if h > 0,
      do: "#{h}h #{pad(m)}m",
      else: "#{m}m #{pad(rem(s, 60))}s"
  end

  def uptime(_), do: "—"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  def accel_label("auto"), do: "Automática"
  def accel_label("tcg"), do: "TCG (emulação)"
  def accel_label("whpx"), do: "WHPX"
  def accel_label("kvm"), do: "KVM"
  def accel_label("hvf"), do: "HVF"
  def accel_label(a), do: a

  @doc "1536 → \"1.5 GiB\", 512 → \"512 MiB\"."
  def memory_label(mib) when is_integer(mib) and mib >= 1024 do
    gib = mib / 1024
    if gib == trunc(gib), do: "#{trunc(gib)} GiB", else: "#{Float.round(gib, 1)} GiB"
  end

  def memory_label(mib), do: "#{mib} MiB"
end
