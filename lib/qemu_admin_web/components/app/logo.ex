defmodule QemuAdminWeb.Components.App.Logo do
  @moduledoc """
  The QEMU Admin mark at icon size: a monitor with a shell prompt `>_` on
  its screen — a machine inside the machine, reduced to its glyph.

  Pure `currentColor`, like the Rockwell Viewer and Eleuther.IO marks: pair
  it with `text-primary svg-glow` and it follows the theme.
  """

  use Surface.Component

  @doc "CSS classes for sizing and color, e.g. \"size-6 text-primary svg-glow\"."
  prop class, :css_class, default: ""

  def render(assigns) do
    ~F"""
    <svg
      viewBox="0 0 32 32"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="2.2"
      stroke-linecap="round"
      stroke-linejoin="round"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <rect x="3" y="5" width="26" height="17" rx="2" />
      <path d="M16 22v5M10.5 27h11" />
      <path d="M9 10.5l3.5 3-3.5 3M15 16.5h6" />
    </svg>
    """
  end
end
