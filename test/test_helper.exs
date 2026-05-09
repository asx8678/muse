exclude_tags =
  case :os.type() do
    {:unix, _} -> [:external_provider]
    _ -> [:external_provider, :unix]
  end

ExUnit.start(exclude: exclude_tags)
