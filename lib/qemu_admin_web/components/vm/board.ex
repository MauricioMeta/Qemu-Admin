defmodule QemuAdminWeb.Components.Vm.Board do
  @moduledoc """
  A development board drawn in SVG (`QemuAdmin.Board`): its body and parts,
  its LEDs and its pin headers, every GPIO coloured by what
  `QemuAdmin.Gpio` reports — an output high or low, an input and the level
  driven on it, a pin given to another function. Clicking an input flips
  the level the outside world drives it to (`gpio_toggle`, `gpio`): a
  button, a switch.

  `compact` draws it small, without labels or clicks (the VM grid).
  """

  use Surface.Component

  alias QemuAdmin.Board

  prop board, :map, required: true

  @doc "`QemuAdmin.Gpio.snapshot/1`, nil when the board is off."
  prop gpio, :map, default: nil

  prop compact, :boolean, default: false

  @doc "Whether the board is powered (the power LED)."
  prop on, :boolean, default: false

  defp pin_state(nil, _g), do: nil
  defp pin_state(gpio, g), do: gpio.pins[g]

  defp clickable?(gpio, compact, g) do
    not compact and gpio != nil and gpio.inputs? and
      match?(%{dir: d} when d != :out, gpio.pins[g])
  end

  defp dot_fill(ref, st) do
    case {ref, st} do
      {:gnd, _} -> "#0b0b0c"
      {r, _} when r in [:v3, :v5, :vin] -> "#f97316"
      {{:flash, _}, _} -> "#3f3f46"
      {r, _} when not is_integer(r) -> "#71717a"
      {_, %{dir: :out, level: 1}} -> "#ef4444"
      {_, %{dir: :out}} -> "#4c0d0d"
      {_, %{dir: :in, level: 1}} -> "#60a5fa"
      {_, %{dir: :in}} -> "#1e3a8a"
      {_, %{dir: :alt}} -> "#a855f7"
      _ -> "#52525b"
    end
  end

  defp label_fill(st) do
    case st do
      %{dir: :out, level: 1} -> "#fca5a5"
      %{dir: :in, level: 1} -> "#60a5fa"
      # the theme's text colour (labels sit off the board too)
      _ -> nil
    end
  end

  defp glow?(st), do: match?(%{dir: :out, level: 1}, st)

  defp describe(board, %{label: label, ref: ref}, st) do
    name =
      case {board.kind, ref} do
        {:avr, g} when is_integer(g) -> "#{label} (#{Board.avr_name(g)})"
        {_, g} when is_integer(g) -> "#{label} (GPIO#{g})"
        {_, {:flash, g}} -> "#{label} (GPIO#{g}, ligado à flash)"
        _ -> label
      end

    state =
      case st do
        %{dir: :out, level: l} ->
          "saída #{if l == 1, do: "alta", else: "baixa"}"

        %{dir: :in, level: l} ->
          "entrada #{if l == 1, do: "alta", else: "baixa"} — clique para inverter"

        %{dir: :alt} ->
          "outra função"

        _ ->
          nil
      end

    Enum.join(Enum.reject([name, state], &is_nil/1), " · ")
  end

  # the dark strip under each header
  defp strip(%{at: {x0, y0}, step: {dx, dy}, pins: pins}) do
    n = length(pins) - 1
    {x1, y1} = {x0 + dx * n, y0 + dy * n}
    %{x: min(x0, x1) - 7, y: min(y0, y1) - 7, w: abs(x1 - x0) + 14, h: abs(y1 - y0) + 14}
  end

  defp label_attrs(%{side: :left, x: x, y: y}),
    do: %{x: x - 10, y: y + 3, anchor: "end", transform: nil}

  defp label_attrs(%{side: :right, x: x, y: y}),
    do: %{x: x + 10, y: y + 3, anchor: "start", transform: nil}

  defp label_attrs(%{side: :above, x: x, y: y}),
    do: %{x: 0, y: 3, anchor: "start", transform: "translate(#{x} #{y - 9}) rotate(-90)"}

  defp label_attrs(%{side: :below, x: x, y: y}),
    do: %{x: 0, y: 3, anchor: "end", transform: "translate(#{x} #{y + 9}) rotate(-90)"}

  defp light?(fill),
    do:
      String.starts_with?(fill, "#c") or String.starts_with?(fill, "#d") or
        String.starts_with?(fill, "#b") or String.starts_with?(fill, "#9")

  defp led_on?(%{gpio: nil}, _gpio, on), do: on
  defp led_on?(%{gpio: g}, gpio, _on), do: match?(%{level: 1}, pin_state(gpio, g))

  def render(assigns) do
    ~F"""
    <svg
      viewBox={"0 0 #{elem(@board.size, 0)} #{elem(@board.size, 1)}"}
      class={"block h-auto w-full select-none", "max-h-full": @compact}
      role="img"
      aria-label={@board.name}
    >
      <defs>
        <filter id="qa-glow" x="-100%" y="-100%" width="300%" height="300%">
          <feGaussianBlur stdDeviation="2.4" result="b" />
          <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
        </filter>
      </defs>
      <rect
        x={@board.body.x}
        y={@board.body.y}
        width={@board.body.w}
        height={@board.body.h}
        rx={@board.body.rx}
        fill={@board.body.fill}
        stroke="#00000055"
      />
      {#for p <- @board.parts}
        <rect x={p.x} y={p.y} width={p.w} height={p.h} rx={p.rx} fill={p.fill} stroke="#00000040" />
        <text
          :if={not @compact}
          x={p.x + p.w / 2}
          y={p.y + p.h / 2 + 3}
          text-anchor="middle"
          font-size="8"
          font-family="ui-monospace, monospace"
          fill={if light?(p.fill), do: "#1f2937", else: "#a1a1aa"}
        >{p.label}</text>
      {/for}
      {#for led <- @board.leds}
        <circle
          cx={led.x}
          cy={led.y}
          r="5"
          fill={if led_on?(led, @gpio, @on), do: led.color, else: "#27272a"}
          stroke="#00000080"
          filter={if led_on?(led, @gpio, @on), do: "url(#qa-glow)"}
        />
        <text
          :if={not @compact}
          x={led.x + 9}
          y={led.y + 3}
          font-size="8"
          fill="#e4e4e7"
          font-family="ui-monospace, monospace"
        >{led.label}</text>
      {/for}
      {#for h <- @board.headers}
        <rect
          x={strip(h).x}
          y={strip(h).y}
          width={strip(h).w}
          height={strip(h).h}
          rx="2"
          fill="#0d0d0f"
        />
      {/for}
      {#for pin <- Board.pins(@board)}
        {#if clickable?(@gpio, @compact, pin.ref)}
          <g id={"pin-#{pin.ref}"} phx-click="gpio_toggle" phx-value-gpio={pin.ref} class="cursor-pointer">
            <title>{describe(@board, pin, pin_state(@gpio, pin.ref))}</title>
            <rect x={pin.x - 6} y={pin.y - 6} width="12" height="12" fill="transparent" />
            <rect
              x={pin.x - 4.5}
              y={pin.y - 4.5}
              width="9"
              height="9"
              rx="1"
              fill="#b8962e"
              stroke="#60a5fa"
              stroke-width="1.2"
            />
            <circle cx={pin.x} cy={pin.y} r="3.4" fill={dot_fill(pin.ref, pin_state(@gpio, pin.ref))} />
          </g>
        {#else}
          <g id={if not @compact and is_integer(pin.ref), do: "pin-#{pin.ref}"}>
            <title :if={not @compact}>{describe(@board, pin, pin_state(@gpio, pin.ref))}</title>
            <rect x={pin.x - 4.5} y={pin.y - 4.5} width="9" height="9" rx="1" fill="#b8962e" />
            <circle
              cx={pin.x}
              cy={pin.y}
              r="3.4"
              fill={dot_fill(pin.ref, pin_state(@gpio, pin.ref))}
              filter={if glow?(pin_state(@gpio, pin.ref)), do: "url(#qa-glow)"}
            />
          </g>
        {/if}
        <text
          :if={not @compact}
          x={label_attrs(pin).x}
          y={label_attrs(pin).y}
          transform={label_attrs(pin).transform}
          text-anchor={label_attrs(pin).anchor}
          font-size="8"
          font-family="ui-monospace, monospace"
          style={if c = label_fill(pin_state(@gpio, pin.ref)), do: "fill: #{c}", else: ""}
          class="fill-base-content/75"
        >{pin.label}</text>
      {/for}
    </svg>
    """
  end
end
