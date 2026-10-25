defmodule QemuAdmin.MixProject do
  use Mix.Project

  def project do
    [
      app: :qemu_admin,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:surface],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {QemuAdmin.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The release Tauri ships inside the desktop app, as in Eleuther.IO: ERTS
  # travels with it, and so does the portable QEMU fetched by `mix qemu.fetch`
  # (copied to `<release>/qemu`, where `QemuAdmin.Qemu` looks first). The
  # machine running QEMU Admin needs neither Erlang nor QEMU installed.
  defp releases do
    [
      qemu_admin: [
        include_executables_for: [:unix, :windows],
        include_erts: true,
        quiet: true,
        steps: [:assemble, &bundle_qemu/1, &bundle_qemu_esp/1]
      ]
    ]
  end

  # `qemu/` sits at the project root rather than in priv/: in dev Mix would
  # copy those few hundred MB into `_build` on every structure rebuild
  # (Windows has no symlinks without developer mode).
  defp bundle_qemu(release) do
    source = Path.expand("qemu")
    target = Path.join(release.path, "qemu")
    File.rm_rf!(target)

    if File.exists?(Path.join(source, "qemu-img.exe")) or
         File.exists?(Path.join(source, "qemu-img")) do
      File.cp_r!(source, target)
    else
      Mix.shell().info([
        :yellow,
        "* qemu/ vazio — a release sai sem QEMU embutido (rode `mix qemu.fetch`)",
        :reset
      ])
    end

    release
  end

  # Espressif's QEMU (the ESP32), from `qemu-esp/` — see QemuAdmin.Qemu.Esp.
  defp bundle_qemu_esp(release) do
    source = Path.expand("qemu-esp")
    target = Path.join(release.path, "qemu-esp")
    File.rm_rf!(target)
    if File.dir?(Path.join(source, "bin")), do: File.cp_r!(source, target)
    release
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:surface, "~> 0.12.3"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm install --no-audit --no-fund"
      ],
      "assets.build": ["compile", "tailwind qemu_admin", "esbuild qemu_admin"],
      "assets.deploy": [
        "tailwind qemu_admin --minify",
        "esbuild qemu_admin --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
