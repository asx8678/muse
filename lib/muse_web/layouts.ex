defmodule MuseWeb.Layouts do
  @moduledoc """
  Application layouts for MuseWeb.
  """

  use MuseWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()}>
      <title>Muse</title>
      <link rel="stylesheet" href="/assets/css/app.css">
      <script defer type="text/javascript" src="/assets/app.js"></script>
    </head>
    <body>
      {@inner_content}
    </body>
    </html>
    """
  end
end
