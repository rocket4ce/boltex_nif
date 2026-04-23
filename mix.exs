defmodule BoltexNif.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/rocket4ce/boltex_nif"

  def project do
    [
      app: :boltex_nif,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Elixir NIF bindings for the neo4rs Rust driver for Neo4j — full Bolt v5 " <>
      "protocol, transactions, streaming, and result summaries, with no Rust " <>
      "toolchain required at install time (precompiled NIFs via rustler_precompiled)."
  end

  defp package do
    [
      name: "boltex_nif",
      licenses: ["MIT"],
      maintainers: ["rocket4ce"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "neo4rs" => "https://github.com/neo4j-labs/neo4rs"
      },
      # Everything needed to build from source (when a precompiled binary
      # isn't available for the target) plus the checksum file that tells
      # rustler_precompiled which artifact to download.
      files: [
        "lib",
        "native/boltex_nif/Cargo.toml",
        "native/boltex_nif/Cargo.lock",
        "native/boltex_nif/src",
        "native/boltex_nif/.gitignore",
        "checksum-*.exs",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"],
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "RELEASING.md": [title: "Releasing (maintainers)"],
        "LICENSE": [title: "License"]
      ],
      groups_for_extras: [
        Guides: ~r/README\.md/,
        Reference: ~r/(CHANGELOG|RELEASING|LICENSE)\.md/
      ],
      groups_for_modules: [
        "Core API": [
          BoltexNif
        ],
        "Graph types": [
          BoltexNif.Node,
          BoltexNif.Relationship,
          BoltexNif.UnboundRelationship,
          BoltexNif.Path,
          BoltexNif.Point
        ],
        "Temporal types": [
          BoltexNif.Duration,
          BoltexNif.Time,
          BoltexNif.DateTime,
          BoltexNif.DateTimeZoneId
        ],
        "Results & diagnostics": [
          BoltexNif.Summary,
          BoltexNif.Summary.Counters,
          BoltexNif.Notification,
          BoltexNif.Notification.InputPosition,
          BoltexNif.Neo4jError
        ]
      ],
      groups_for_docs: [
        "Connection": &(&1[:group] == :connection),
        "Auto-commit queries": &(&1[:group] == :auto_commit),
        "Transactions": &(&1[:group] == :transactions),
        "Streaming": &(&1[:group] == :streaming)
      ],
      nest_modules_by_prefix: [BoltexNif]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.9"},
      # Needed only when building the NIF from source (unsupported target or
      # `FORCE_BOLTEX_BUILD=1`). Optional so ordinary consumers that rely on
      # the precompiled binary don't pull `rustler` into their dep tree.
      {:rustler, "~> 0.37", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
