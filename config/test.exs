import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :qemu_admin, QemuAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4012],
  secret_key_base: "t8Yk2Lm5Qw9Er3Ty6Ui1Op4As7Df0Gh2Jk5Lz8Xc1Vb4Nm7Qw0Er3Ty6Ui9Op2As",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# VMs, settings and downloaded QEMU go to a throwaway folder, never the
# user's ~/.qemu_admin.
config :qemu_admin, :data_dir, Path.join(System.tmp_dir!(), "qemu_admin_test")
