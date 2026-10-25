import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts.

if System.get_env("PHX_SERVER") do
  config :qemu_admin, QemuAdminWeb.Endpoint, server: true
end

config :qemu_admin, QemuAdminWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4010"))]

# Whether the UI is inside the app's own window or in a browser tab, as in
# Eleuther.IO. The Tauri shell sets it when it starts the release
# (`src-tauri/src/main.rs`); `mix phx.server` doesn't. It decides the title
# bar (the window is undecorated) and the close guard (running VMs). To work
# on the bar without the desktop build:
#
#     QEMU_ADMIN_DESKTOP=1 mix phx.server
config :qemu_admin, desktop?: System.get_env("QEMU_ADMIN_DESKTOP") == "1"

# Where VMs, settings and a QEMU downloaded at runtime live. Dev keeps them
# in ~/.qemu_admin (test overrides it in config/test.exs).
if data_dir = System.get_env("QEMU_ADMIN_DATA_DIR") do
  config :qemu_admin, :data_dir, data_dir
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :qemu_admin, QemuAdminWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/qemu_admin_web/router\.ex$",
        ~r"lib/qemu_admin_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # Production here means "the release bundled inside the Tauri desktop
  # app", as in Eleuther.IO:
  #
  #   * the endpoint binds loopback only — it starts and stops VMs;
  #   * state lives in a per-user data directory (the installed release is
  #     not writable);
  #   * the secret is generated once and kept beside that state.
  data_dir =
    System.get_env("QEMU_ADMIN_DATA_DIR") ||
      :filename.basedir(:user_data, ~c"qemu_admin") |> List.to_string()

  File.mkdir_p!(data_dir)

  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      key when is_binary(key) and byte_size(key) >= 64 ->
        key

      _ ->
        path = Path.join(data_dir, "secret_key_base")

        case File.read(path) do
          {:ok, key} when byte_size(key) >= 64 ->
            key

          _ ->
            key = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
            File.write!(path, key)
            key
        end
    end

  port = String.to_integer(System.get_env("PORT", "4010"))

  config :qemu_admin, :data_dir, data_dir

  config :qemu_admin, QemuAdminWeb.Endpoint,
    server: true,
    url: [host: "127.0.0.1", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    # The port is picked at launch, so the allowed origins are built here.
    check_origin: ["http://127.0.0.1:#{port}", "http://localhost:#{port}"],
    secret_key_base: secret_key_base
end
