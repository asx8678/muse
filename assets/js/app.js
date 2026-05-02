// Muse LiveView client — requires esbuild bundling to resolve phoenix deps.
// Full asset bundling remains a later step; this file is esbuild source only.
//
// When bundled, the output should replace the placeholder below and
// the <script> tag in HomeLive should point to the bundled output.

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
liveSocket.connect()
