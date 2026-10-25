# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :qemu_admin,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :qemu_admin, QemuAdminWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: QemuAdminWeb.ErrorHTML, json: QemuAdminWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: QemuAdmin.PubSub,
  live_view: [signing_salt: "q3mUad7n"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r",
  # no colocated hooks here; Windows refuses the symlink without admin rights
  colocated_assets: [disable_symlink_warning: true]

# The portable QEMU fetched by `mix qemu.fetch` (Windows builds by Stefan
# Weil, the ones linked from qemu.org). Only these system emulators and their
# firmware are kept, out of the ~30 the installer carries.
config :qemu_admin, :qemu_fetch,
  index_url: "https://qemu.weilnetz.de/w64/",
  targets: ~w(x86_64 i386 aarch64 arm avr)

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  qemu_admin: [
    args:
      ~w(js/app.js --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  qemu_admin: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :vm]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
