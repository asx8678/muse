exclude_tags =
  case :os.type() do
    {:unix, _} -> [:external_provider, :timing_baseline]
    _ -> [:external_provider, :timing_baseline, :unix]
  end

ExUnit.start(exclude: exclude_tags)
