defmodule QemuAdmin.Board do
  @moduledoc """
  The development boards a VM can be — an ESP32 DevKit, an Arduino, a
  Raspberry Pi — told apart by QEMU's machine (`for_machine/1`). Each has
  what the Placa view draws (`QemuAdminWeb.Components.Vm.Board`): its body
  and parts, and its pin headers, every pin with its silkscreen label and
  what it is (`ref`):

    * an integer — a GPIO the IO view shows and drives: the chip's GPIO
      number on an ESP32 and a Raspberry Pi; on an AVR the port bit as
      `port * 8 + bit`, ports A, B, C… (no I) numbered from 0 (`avr_gpio/2`);
    * `:v3`, `:v5`, `:vin`, `:gnd`, `:rst`, `:nc`, `:other` — power and the rest;
    * `{:flash, gpio}` — an ESP32's pins wired to its SPI flash, not usable.

  Geometry is in SVG units: `size` is the drawing's `{width, height}`, a
  header a straight row of pins (`at` the first, `step` to the next, the
  labels on `label` side) where `nil` leaves a gap.

  `io` says how `QemuAdmin.Gpio` follows the pins: `:esp32` and `:avr`
  through QEMU's gdbstub (their emulated GPIO keeps no state), `:raspi` by
  reading the BCM2835's registers (`gpio_base`) over QMP.
  """

  @avr_ports ~w(A B C D E F G H J K L)

  @doc "An AVR port bit as the integer the IO view uses: `avr_gpio(\"B\", 5)` → 13."
  def avr_gpio(port, bit), do: Enum.find_index(@avr_ports, &(&1 == port)) * 8 + bit

  @doc "Back: 13 → \"PB5\"."
  def avr_name(gpio), do: "P#{Enum.at(@avr_ports, div(gpio, 8))}#{rem(gpio, 8)}"

  def avr_ports, do: @avr_ports

  # ------------------------------------------------------------- ESP32

  @esp32_left [
    {"3V3", :v3},
    {"EN", :rst},
    {"SVP", 36},
    {"SVN", 39},
    {"IO34", 34},
    {"IO35", 35},
    {"IO32", 32},
    {"IO33", 33},
    {"IO25", 25},
    {"IO26", 26},
    {"IO27", 27},
    {"IO14", 14},
    {"IO12", 12},
    {"GND", :gnd},
    {"IO13", 13},
    {"SD2", {:flash, 9}},
    {"SD3", {:flash, 10}},
    {"CMD", {:flash, 11}},
    {"5V", :v5}
  ]

  @esp32_right [
    {"GND", :gnd},
    {"IO23", 23},
    {"IO22", 22},
    {"TXD0", 1},
    {"RXD0", 3},
    {"IO21", 21},
    {"GND", :gnd},
    {"IO19", 19},
    {"IO18", 18},
    {"IO5", 5},
    {"IO17", 17},
    {"IO16", 16},
    {"IO4", 4},
    {"IO0", 0},
    {"IO2", 2},
    {"IO15", 15},
    {"SD1", {:flash, 8}},
    {"SD0", {:flash, 7}},
    {"CLK", {:flash, 6}}
  ]

  @esp32s3_left [
    {"3V3", :v3},
    {"3V3", :v3},
    {"RST", :rst},
    {"4", 4},
    {"5", 5},
    {"6", 6},
    {"7", 7},
    {"15", 15},
    {"16", 16},
    {"17", 17},
    {"18", 18},
    {"8", 8},
    {"3", 3},
    {"46", 46},
    {"9", 9},
    {"10", 10},
    {"11", 11},
    {"12", 12},
    {"13", 13},
    {"14", 14},
    {"5V", :v5},
    {"G", :gnd}
  ]

  @esp32s3_right [
    {"G", :gnd},
    {"TX", 43},
    {"RX", 44},
    {"1", 1},
    {"2", 2},
    {"42", 42},
    {"41", 41},
    {"40", 40},
    {"39", 39},
    {"38", 38},
    {"37", 37},
    {"36", 36},
    {"35", 35},
    {"0", 0},
    {"45", 45},
    {"48", 48},
    {"47", 47},
    {"21", 21},
    {"20", 20},
    {"19", 19},
    {"G", :gnd},
    {"G", :gnd}
  ]

  defp devkit(id, machine, name, chip, left, right, leds) do
    n = length(left)
    height = 250 + n * 14

    %{
      id: id,
      machine: machine,
      arch: "xtensa",
      kind: :esp32,
      io: :esp32,
      name: name,
      chip: chip,
      size: {380, height + 20},
      body: %{x: 90, y: 10, w: 200, h: height, fill: "#17191c", rx: 8},
      parts: [
        %{x: 112, y: 22, w: 156, h: 150, fill: "#b9bec4", rx: 3, label: chip_label(machine)},
        %{x: 112, y: 22, w: 156, h: 34, fill: "#9ea4ab", rx: 3, label: "antena"},
        %{x: 168, y: height - 14, w: 44, h: 26, fill: "#c3c7cc", rx: 2, label: "USB"},
        %{x: 104, y: height - 40, w: 22, h: 16, fill: "#2b2f35", rx: 2, label: "EN"},
        %{x: 254, y: height - 40, w: 22, h: 16, fill: "#2b2f35", rx: 2, label: "BOOT"},
        %{x: 160, y: 196, w: 60, h: 34, fill: "#0f1012", rx: 2, label: "CP2102"}
      ],
      leds: leds,
      headers: [
        %{at: {104, 236}, step: {0, 14}, label: :left, pins: left},
        %{at: {276, 236}, step: {0, 14}, label: :right, pins: right}
      ]
    }
  end

  defp chip_label("esp32"), do: "ESP32-WROOM-32"
  defp chip_label("esp32s3"), do: "ESP32-S3-WROOM-1"

  # ------------------------------------------------------------- Arduino

  defp d(n, port, bit), do: {to_string(n), avr_gpio(port, bit)}
  defp a(n, port, bit), do: {"A#{n}", avr_gpio(port, bit)}

  defp uno do
    %{
      id: "arduino-uno",
      machine: "arduino-uno",
      arch: "avr",
      kind: :avr,
      io: :avr,
      name: "Arduino Uno",
      chip: "ATmega328P (16 MHz)",
      size: {560, 380},
      body: %{x: 30, y: 50, w: 500, h: 290, fill: "#0e7c86", rx: 10},
      parts: [
        %{x: 6, y: 86, w: 76, h: 62, fill: "#c3c7cc", rx: 3, label: "USB"},
        %{x: 10, y: 262, w: 62, h: 52, fill: "#1b1b1b", rx: 4, label: "DC"},
        %{x: 290, y: 238, w: 200, h: 44, fill: "#1b1b1b", rx: 3, label: "ATMEGA328P"},
        %{x: 120, y: 180, w: 42, h: 42, fill: "#1b1b1b", rx: 2, label: "16U2"},
        %{x: 410, y: 140, w: 70, h: 30, fill: "#d9d9d9", rx: 6, label: "RESET"}
      ],
      leds: [
        %{x: 214, y: 128, gpio: avr_gpio("B", 5), label: "L", color: "#f59e0b"},
        %{x: 404, y: 100, gpio: nil, label: "ON", color: "#22c55e"}
      ],
      headers: [
        %{
          at: {150, 66},
          step: {16, 0},
          label: :above,
          pins: [
            {"SCL", avr_gpio("C", 5)},
            {"SDA", avr_gpio("C", 4)},
            {"AREF", :other},
            {"GND", :gnd},
            d(13, "B", 5),
            d(12, "B", 4),
            d(11, "B", 3),
            d(10, "B", 2),
            d(9, "B", 1),
            d(8, "B", 0),
            nil,
            d(7, "D", 7),
            d(6, "D", 6),
            d(5, "D", 5),
            d(4, "D", 4),
            d(3, "D", 3),
            d(2, "D", 2),
            {"TX 1", avr_gpio("D", 1)},
            {"RX 0", avr_gpio("D", 0)}
          ]
        },
        %{
          at: {198, 324},
          step: {16, 0},
          label: :below,
          pins: [
            {"NC", :nc},
            {"IOREF", :v5},
            {"RESET", :rst},
            {"3V3", :v3},
            {"5V", :v5},
            {"GND", :gnd},
            {"GND", :gnd},
            {"VIN", :vin},
            nil,
            a(0, "C", 0),
            a(1, "C", 1),
            a(2, "C", 2),
            a(3, "C", 3),
            a(4, "C", 4),
            a(5, "C", 5)
          ]
        }
      ]
    }
  end

  # The Mega's digital pins, as its port bits (the Arduino core's table).
  @mega_digital [
    {"E", 0},
    {"E", 1},
    {"E", 4},
    {"E", 5},
    {"G", 5},
    {"E", 3},
    {"H", 3},
    {"H", 4},
    {"H", 5},
    {"H", 6},
    {"B", 4},
    {"B", 5},
    {"B", 6},
    {"B", 7},
    {"J", 1},
    {"J", 0},
    {"H", 1},
    {"H", 0},
    {"D", 3},
    {"D", 2},
    {"D", 1},
    {"D", 0},
    {"A", 0},
    {"A", 1},
    {"A", 2},
    {"A", 3},
    {"A", 4},
    {"A", 5},
    {"A", 6},
    {"A", 7},
    {"C", 7},
    {"C", 6},
    {"C", 5},
    {"C", 4},
    {"C", 3},
    {"C", 2},
    {"C", 1},
    {"C", 0},
    {"D", 7},
    {"G", 2},
    {"G", 1},
    {"G", 0},
    {"L", 7},
    {"L", 6},
    {"L", 5},
    {"L", 4},
    {"L", 3},
    {"L", 2},
    {"L", 1},
    {"L", 0},
    {"B", 3},
    {"B", 2},
    {"B", 1},
    {"B", 0}
  ]

  defp md(n) do
    {port, bit} = Enum.at(@mega_digital, n)
    {to_string(n), avr_gpio(port, bit)}
  end

  defp mega(id, machine, name, chip) do
    %{
      id: id,
      machine: machine,
      arch: "avr",
      kind: :avr,
      io: :avr,
      name: name,
      chip: chip,
      size: {820, 400},
      body: %{x: 30, y: 50, w: 740, h: 310, fill: "#0e7c86", rx: 10},
      parts: [
        %{x: 6, y: 86, w: 76, h: 62, fill: "#c3c7cc", rx: 3, label: "USB"},
        %{x: 10, y: 282, w: 62, h: 52, fill: "#1b1b1b", rx: 4, label: "DC"},
        %{x: 330, y: 170, w: 110, h: 110, fill: "#1b1b1b", rx: 3, label: "ATMEGA2560"},
        %{x: 120, y: 190, w: 42, h: 42, fill: "#1b1b1b", rx: 2, label: "16U2"}
      ],
      leds: [
        %{x: 214, y: 128, gpio: avr_gpio("B", 7), label: "L", color: "#f59e0b"},
        %{x: 470, y: 100, gpio: nil, label: "ON", color: "#22c55e"}
      ],
      headers: [
        %{
          at: {150, 66},
          step: {16, 0},
          label: :above,
          pins:
            [
              {"SCL", avr_gpio("D", 0)},
              {"SDA", avr_gpio("D", 1)},
              {"AREF", :other},
              {"GND", :gnd}
            ] ++
              Enum.map(13..8//-1, &md/1) ++
              [nil] ++ Enum.map(7..0//-1, &md/1) ++ [nil] ++ Enum.map(14..21, &md/1)
        },
        %{
          at: {700, 92},
          step: {0, 16},
          label: :left,
          pins: [{"5V", :v5} | Enum.map(22..52//2, &md/1)] ++ [{"GND", :gnd}]
        },
        %{
          at: {716, 92},
          step: {0, 16},
          label: :right,
          pins: [{"5V", :v5} | Enum.map(23..53//2, &md/1)] ++ [{"GND", :gnd}]
        },
        %{
          at: {198, 344},
          step: {16, 0},
          label: :below,
          pins:
            [
              {"NC", :nc},
              {"IOREF", :v5},
              {"RESET", :rst},
              {"3V3", :v3},
              {"5V", :v5},
              {"GND", :gnd},
              {"GND", :gnd},
              {"VIN", :vin},
              nil
            ] ++
              Enum.map(0..7, &a(&1, "F", &1)) ++
              [nil] ++ Enum.map(0..7, &{"A#{&1 + 8}", avr_gpio("K", &1)})
        }
      ]
    }
  end

  # --------------------------------------------------------- Raspberry Pi

  # The 40-pin header, by physical pin number.
  @pi_header %{
    1 => {"3V3", :v3},
    2 => {"5V", :v5},
    3 => 2,
    4 => {"5V", :v5},
    5 => 3,
    6 => {"GND", :gnd},
    7 => 4,
    8 => 14,
    9 => {"GND", :gnd},
    10 => 15,
    11 => 17,
    12 => 18,
    13 => 27,
    14 => {"GND", :gnd},
    15 => 22,
    16 => 23,
    17 => {"3V3", :v3},
    18 => 24,
    19 => 10,
    20 => {"GND", :gnd},
    21 => 9,
    22 => 25,
    23 => 11,
    24 => 8,
    25 => {"GND", :gnd},
    26 => 7,
    27 => 0,
    28 => 1,
    29 => 5,
    30 => {"GND", :gnd},
    31 => 6,
    32 => 12,
    33 => 13,
    34 => {"GND", :gnd},
    35 => 19,
    36 => 16,
    37 => 26,
    38 => 20,
    39 => {"GND", :gnd},
    40 => 21
  }

  defp pi_pin(n) do
    case @pi_header[n] do
      g when is_integer(g) -> {"GPIO#{g}", g}
      pin -> pin
    end
  end

  defp raspi(id, machine, arch, name, chip, opts) do
    zero? = Keyword.get(opts, :zero, false)
    {w, h} = if zero?, do: {420, 190}, else: {520, 340}

    parts =
      if zero? do
        [
          %{x: 190, y: 116, w: 56, h: 56, fill: "#2a2a2a", rx: 2, label: "BCM2835"},
          %{x: 40, y: 150, w: 70, h: 34, fill: "#c3c7cc", rx: 3, label: "mini HDMI"},
          %{x: 300, y: 158, w: 40, h: 24, fill: "#c3c7cc", rx: 2, label: "USB"},
          %{x: 360, y: 158, w: 40, h: 24, fill: "#c3c7cc", rx: 2, label: "PWR"}
        ]
      else
        [
          %{x: 170, y: 170, w: 80, h: 80, fill: "#2a2a2a", rx: 2, label: chip_short(chip)},
          %{x: 446, y: 108, w: 84, h: 62, fill: "#c3c7cc", rx: 2, label: "USB"},
          %{x: 446, y: 180, w: 84, h: 62, fill: "#c3c7cc", rx: 2, label: "USB"},
          %{x: 446, y: 252, w: 84, h: 66, fill: "#c3c7cc", rx: 2, label: "Ethernet"},
          %{x: 120, y: 302, w: 70, h: 40, fill: "#c3c7cc", rx: 2, label: "HDMI"},
          %{x: 40, y: 306, w: 40, h: 30, fill: "#c3c7cc", rx: 2, label: "PWR"},
          %{x: 250, y: 300, w: 46, h: 30, fill: "#1b1b1b", rx: 2, label: "áudio"}
        ]
      end

    %{
      id: id,
      machine: machine,
      arch: arch,
      kind: :raspi,
      io: :raspi,
      name: name,
      chip: chip,
      gpio_base: Keyword.fetch!(opts, :gpio_base),
      memory: Keyword.fetch!(opts, :memory),
      kernel: Keyword.fetch!(opts, :kernel),
      dtb: Keyword.fetch!(opts, :dtb),
      # the PL011 QEMU wires to -serial: the boards with Bluetooth give it
      # to the radio (DT alias serial1), so Linux names it ttyAMA1 there
      uart: Keyword.get(opts, :uart, "ttyAMA1"),
      usb?: Keyword.get(opts, :usb, true),
      size: {w + 20, h + 70},
      body: %{x: 10, y: 60, w: w, h: h - 60, fill: "#1f7a3a", rx: 14},
      parts: parts,
      leds: [
        %{x: 30, y: if(zero?, do: 130, else: 230), gpio: nil, label: "PWR", color: "#ef4444"}
      ],
      headers: [
        %{at: {64, 74}, step: {16, 0}, label: :above, pins: Enum.map(2..40//2, &pi_pin/1)},
        %{at: {64, 90}, step: {16, 0}, label: :below, pins: Enum.map(1..39//2, &pi_pin/1)}
      ]
    }
  end

  defp chip_short(chip), do: chip |> String.split(" ") |> List.first()

  # ---------------------------------------------------------------- catalog

  @doc "Every board, in menu order."
  def all do
    [
      devkit(
        "esp32-devkitc",
        "esp32",
        "ESP32-DevKitC",
        "ESP32 (Xtensa LX6, 2 núcleos)",
        @esp32_left,
        @esp32_right,
        [%{x: 240, y: 200, gpio: 2, label: "IO2", color: "#3b82f6"}]
      ),
      devkit(
        "esp32s3-devkitc",
        "esp32s3",
        "ESP32-S3-DevKitC-1",
        "ESP32-S3 (Xtensa LX7, 2 núcleos)",
        @esp32s3_left,
        @esp32s3_right,
        []
      ),
      uno(),
      mega(
        "arduino-mega2560",
        "arduino-mega-2560-v3",
        "Arduino Mega 2560",
        "ATmega2560 (16 MHz)"
      ),
      mega("arduino-mega", "arduino-mega", "Arduino Mega", "ATmega1280 (16 MHz)"),
      raspi(
        "raspi3b",
        "raspi3b",
        "aarch64",
        "Raspberry Pi 3 B",
        "BCM2837 (Cortex-A53, 4 núcleos)",
        gpio_base: 0x3F200000,
        memory: 1024,
        kernel: "kernel8.img",
        dtb: "bcm2710-rpi-3-b.dtb"
      ),
      raspi(
        "raspi3ap",
        "raspi3ap",
        "aarch64",
        "Raspberry Pi 3 A+",
        "BCM2837 (Cortex-A53, 4 núcleos)",
        gpio_base: 0x3F200000,
        memory: 512,
        kernel: "kernel8.img",
        dtb: "bcm2710-rpi-3-a-plus.dtb"
      ),
      raspi(
        "raspi4b",
        "raspi4b",
        "aarch64",
        "Raspberry Pi 4 B",
        "BCM2711 (Cortex-A72, 4 núcleos)",
        gpio_base: 0xFE200000,
        memory: 2048,
        kernel: "kernel8.img",
        dtb: "bcm2711-rpi-4-b.dtb",
        usb: false
      ),
      raspi("raspi2b", "raspi2b", "arm", "Raspberry Pi 2 B", "BCM2836 (Cortex-A7, 4 núcleos)",
        gpio_base: 0x3F200000,
        memory: 1024,
        kernel: "kernel7.img",
        dtb: "bcm2709-rpi-2-b.dtb",
        uart: "ttyAMA0"
      ),
      raspi("raspi0", "raspi0", "arm", "Raspberry Pi Zero", "BCM2835 (ARM1176, 1 núcleo)",
        gpio_base: 0x20200000,
        memory: 512,
        kernel: "kernel.img",
        dtb: "bcm2708-rpi-zero.dtb",
        uart: "ttyAMA0",
        zero: true
      ),
      cortexm("netduinoplus2", "Netduino Plus 2", "STM32F405 (Cortex-M4, 168 MHz)")
    ]
  end

  # A Cortex-M board: nothing drawn (`headers: []`) and no pins followed
  # (`io: nil`) yet — its views are the Serial and the Firmware.
  defp cortexm(id, name, chip) do
    %{
      id: id,
      machine: id,
      arch: "arm",
      kind: :cortexm,
      io: nil,
      name: name,
      chip: chip,
      size: {320, 200},
      body: nil,
      parts: [],
      leds: [],
      headers: []
    }
  end

  @doc "The board QEMU's `machine` emulates, or nil (a PC)."
  def for_machine(machine), do: Enum.find(all(), &(&1.machine == machine))

  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The boards of one kind (`:esp32`, `:avr`, `:raspi`)."
  def of_kind(kind), do: Enum.filter(all(), &(&1.kind == kind))

  @doc """
  Every pin with its position: `%{label:, ref:, x:, y:, side:}` — `side`
  where its label goes.
  """
  def pins(board) do
    for %{at: {x0, y0}, step: {dx, dy}} = h <- board.headers,
        {pin, i} <- Enum.with_index(h.pins),
        pin != nil do
      {label, ref} =
        case pin do
          {label, ref} -> {label, ref}
        end

      %{label: label, ref: ref, x: x0 + dx * i, y: y0 + dy * i, side: h.label}
    end
  end

  @doc "The GPIOs on the board's headers (the ones `QemuAdmin.Gpio` reports)."
  def gpios(board) do
    for %{ref: g} <- pins(board), is_integer(g), uniq: true, do: g
  end
end
