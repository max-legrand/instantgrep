%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      checks: %{
        enabled: [
          {Credo.Check.Design.AliasUsage, priority: :low, if_nested_deeper_than: 2},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12},
          {Credo.Check.Refactor.Nesting, max_nesting: 3}
        ]
      }
    }
  ]
}
