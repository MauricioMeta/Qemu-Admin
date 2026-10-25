defmodule QemuAdminWeb.Components.App.PageHeader do
  @moduledoc """
  The bar on top of the main area, as in the Rockwell Viewer and the Hypermodel:

    1. the open VMs' tabs (`tabs`, `App.Tabs`), when there are any: the window's
       top line, which the rail's and the panel's headers line up with;
    2. the toolbar (`--qa-bar`, 34 px) **under the tabs**: a title or the VM's
       power state at the left (`nav`), the page's view switch centred (`center`)
       and its controls at the right (`buttons`). With no tabs open it is the top
       line itself;
    3. the path to the page (`breadcrumb`), a slim line as high as the footer.
  """

  use Surface.Component

  @doc "At the left of the toolbar."
  slot nav

  @doc "Centred on the toolbar: the page's view switch."
  slot center

  @doc "At the right of the toolbar: the page's controls (`App.IconButton`)."
  slot buttons

  @doc "The open VMs' tab bar (`App.Tabs`), under the toolbar."
  slot tabs

  @doc "The last line: where the page is."
  slot breadcrumb, required: true

  def render(assigns) do
    ~F"""
    <header id="page-header" class="shrink-0 text-xs">
      <#slot {@tabs} />
      <div
        id="page-toolbar"
        class="grid h-[var(--qa-bar)] grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3 border-b border-primary/20 px-3"
      >
        <div class="flex min-w-0 items-center justify-self-stretch gap-2 overflow-hidden">
          <#slot {@nav} />
        </div>
        <div class="min-w-0 justify-self-center">
          <#slot {@center} />
        </div>
        <div class="flex min-w-0 items-center justify-end justify-self-end gap-1">
          <#slot {@buttons} />
        </div>
      </div>
      <div id="page-path" class="flex h-8 items-center gap-2 border-b border-primary/20 px-4">
        <#slot {@breadcrumb} />
      </div>
    </header>
    """
  end
end
