[
  import_deps: [:phoenix, :surface],
  plugins: [Phoenix.LiveView.HTMLFormatter, Surface.Formatter.Plugin],
  inputs: ["*.{heex,sface,ex,exs}", "{config,lib,test}/**/*.{heex,sface,ex,exs}"]
]
