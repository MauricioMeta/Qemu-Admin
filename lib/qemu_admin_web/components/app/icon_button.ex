defmodule QemuAdminWeb.Components.App.IconButton do
  @moduledoc """
  A button of the page header: an icon in a 28 px square, grey until hovered.
  With `active` (a toggle) it stays in the primary colour while on; `tone`
  colours it for what it does (`success` to start, `error` to force off).
  `disabled` greys it out.

  `click` is the event's name or a `Phoenix.LiveView.JS` command; `value`
  goes as `phx-value-id`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  prop id, :string, required: true
  prop title, :string, required: true
  prop click, :any, required: true
  prop value, :any, default: nil

  @doc "The `hero-*` icon; omit for a text button (the default slot)."
  prop icon, :string, default: nil

  @doc "nil for a plain button; true/false for a toggle that is on/off."
  prop active, :any, default: nil

  @doc "nil, \"success\", \"warning\" or \"error\": the colour on hover."
  prop tone, :any, default: nil

  prop disabled, :boolean, default: false

  @doc "A confirmation asked before the click goes (`data-confirm`)."
  prop confirm, :any, default: nil

  slot default

  def render(assigns) do
    ~F"""
    <button
      type="button"
      id={@id}
      phx-click={@click}
      phx-value-id={@value}
      title={@title}
      disabled={@disabled}
      data-confirm={@confirm}
      class={
        "grid h-7 shrink-0 place-items-center rounded hover:bg-base-300 disabled:pointer-events-none disabled:opacity-40",
        "size-7": @icon != nil,
        "px-2 gap-1 grid-flow-col font-mono text-[0.68rem]": @icon == nil,
        "text-primary": @active == true,
        "text-base-content/55 hover:text-primary": @active != true and is_nil(@tone),
        "text-success/80 hover:text-success": @tone == "success",
        "text-warning/80 hover:text-warning": @tone == "warning",
        "text-error/80 hover:text-error": @tone == "error"
      }
    >
      <.icon :if={@icon} name={@icon} class="size-4" />
      <#slot />
    </button>
    """
  end
end
