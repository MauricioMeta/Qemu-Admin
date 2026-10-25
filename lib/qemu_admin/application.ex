defmodule QemuAdmin.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QemuAdminWeb.Telemetry,
      {Phoenix.PubSub, name: QemuAdmin.PubSub},
      QemuAdmin.Settings,
      {Registry, keys: :unique, name: QemuAdmin.Registry},
      # owns the runtime table the VmServers write and the page reads
      QemuAdmin.VmSupervisor,
      {QemuAdmin.Qemu.InstallJob, :qemu},
      {QemuAdmin.Qemu.InstallJob, :esp},
      QemuAdmin.Images,
      # Start to serve requests, typically the last entry
      QemuAdminWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: QemuAdmin.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QemuAdminWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
