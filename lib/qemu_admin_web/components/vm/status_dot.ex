defmodule QemuAdminWeb.Components.Vm.StatusDot do
  @moduledoc """
  A VM's state as a dot: green and pulsing while running, amber paused,
  blue starting/stopping, grey off. `label` adds the word beside it.
  """

  use Surface.Component

  prop status, :atom, default: :stopped
  prop label, :boolean, default: false

  def text(:running), do: "Ligada"
  def text(:paused), do: "Pausada"
  def text(:starting), do: "Iniciando"
  def text(:stopping), do: "Desligando"
  def text(_), do: "Desligada"

  def render(assigns) do
    ~F"""
    <span class="inline-flex shrink-0 items-center gap-1.5" title={text(@status)}>
      <span class={
        "inline-block size-1.5 rounded-full",
        "bg-success text-success status-dot-live": @status == :running,
        "bg-warning text-warning": @status == :paused,
        "bg-info text-info animate-pulse": @status in [:starting, :stopping],
        "bg-base-content/25": @status not in [:running, :paused, :starting, :stopping]
      } />
      <span
        :if={@label}
        class={
          "text-[0.68rem] font-semibold uppercase tracking-wider",
          "text-success": @status == :running,
          "text-warning": @status == :paused,
          "text-info": @status in [:starting, :stopping],
          "text-base-content/40": @status not in [:running, :paused, :starting, :stopping]
        }
      >{text(@status)}</span>
    </span>
    """
  end
end
