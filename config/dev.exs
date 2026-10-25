import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :qemu_admin, QemuAdminWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4010],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "Wv0x8V2r3Hc1yq9jK7m4pB6tN5sD2fG8hJ3kL1zX9cV7bN4mQ2wE5rT8yU1iO6pA",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:qemu_admin, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:qemu_admin, ~w(--watch)]}
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
