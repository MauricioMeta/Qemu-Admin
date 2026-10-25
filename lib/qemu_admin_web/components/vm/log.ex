defmodule QemuAdminWeb.Components.Vm.Log do
  @moduledoc """
  What QEMU printed (`qemu.log` / the VmServer's ring buffer), newest at the
  bottom, following new lines as they come (`LogTail` hook). The lines are a
  stream (`@streams.log`), so a chatty VM does not resend the whole log.
  """

  use Surface.Component

  @doc "The `:log` stream."
  prop lines, :any, required: true

  def render(assigns) do
    ~F"""
    <div
      id="vm-log"
      phx-hook="LogTail"
      phx-update="stream"
      class="min-h-0 flex-1 overflow-y-auto bg-base-300/40 p-4 font-mono text-[0.7rem] leading-relaxed"
    >
      <div
        :for={{dom_id, line} <- @lines}
        id={dom_id}
        class={
          "whitespace-pre-wrap break-all",
          "text-base-content/40": String.starts_with?(line.text, "#"),
          "text-error":
            line.text =~ ~r/error|erro|failed|falh/i and not String.starts_with?(line.text, "#"),
          "text-base-content/80": not String.starts_with?(line.text, "#")
        }
      >{line.text}</div>
      <div id="vm-log-empty" class="hidden only:block text-base-content/35">Nada ainda.</div>
    </div>
    """
  end
end
