"""Exercise the plugin's real curl downloader against a loopback-only HTTP server."""

import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


def main():
    if not shutil.which("curl"):
        print("Download integration skipped: curl unavailable")
        return
    repo = Path(__file__).resolve().parents[1]
    png = (repo / "tests/fixtures/test_4x4.png").read_bytes()
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "ftp://127.0.0.1:1/forbidden")
                self.end_headers()
                return
            self.send_response(200)
            data = b"not an image" if self.path == "/broken.png" else png
            self.send_header("Content-Length", str(len(data) + (100 if self.path == "/partial.png" else 0)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="md-render-download-integration-") as directory:
            temp = Path(directory)
            base = f"http://127.0.0.1:{server.server_port}"
            (temp / ".curlrc").write_text(f'url = "{base}/curlrc-trap"\n')
            runner = temp / "check.lua"
            runner.write_text(r'''
local config = vim.json.decode(assert(os.getenv "MD_RENDER_SECURITY_CONFIG"))
package.path = config.repo .. "/lua/?.lua;" .. config.repo .. "/lua/?/init.lua;" .. package.path
vim.fn.stdpath = function() return config.temp end
local real_system, codes = vim.system, {}
vim.system = function(cmd, opts, callback)
  return real_system(cmd, opts, function(result)
    codes[#codes + 1] = result.code
    callback(result)
  end)
end
local image = require "md-render.image"
for _, name in ipairs { "/ordinary.png", "/brace{a,b}.png", "/bracket[1-3].png", "/redirect", "/broken.png", "/partial.png" } do
  local done, output = false, nil
  image.download_async(config.base .. name, function(path) done, output = true, path end)
  assert(vim.wait(20000, function() return done end), "download timed out: " .. name)
  local success = name == "/ordinary.png" or name == "/brace{a,b}.png" or name == "/bracket[1-3].png"
  assert((output ~= nil) == success, "unexpected result: " .. name)
  if success then assert(image.image_dimensions(output) == 4) end
  if name == "/redirect" then assert(codes[#codes] == 1, "redirect was not rejected as a forbidden protocol") end
end
local executable = vim.fn.executable
vim.fn.executable = function(name) return (name == "plantuml" or name == "java") and 0 or executable(name) end
image.reset_cache()
image.setup { plantuml_server = config.base .. "/plantuml" }
local done, output = false, nil
image.render_plantuml_async("@startuml\nAlice -> Bob\n@enduml", function(path) done, output = true, path end)
assert(vim.wait(20000, function() return done end) and output, "remote PlantUML download failed")
assert(image.image_dimensions(output) == 4)
''')
            env = os.environ | {
                "MD_RENDER_SECURITY_CONFIG": json.dumps({"repo": str(repo), "temp": str(temp), "base": base}),
                "XDG_CACHE_HOME": str(temp / "xdg-cache"),
                "XDG_STATE_HOME": str(temp / "xdg-state"),
                "NVIM_LOG_FILE": str(temp / "nvim.log"),
                "CURL_HOME": str(temp),
            }
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "--noplugin", "-l", str(runner)],
                cwd=repo, env=env, capture_output=True, text=True, timeout=60,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert requests[:6] == [
                "/ordinary.png", "/brace{a,b}.png", "/bracket[1-3].png", "/redirect", "/broken.png", "/partial.png",
            ], requests
            assert len(requests) == 7 and requests[6].startswith("/plantuml/png/~h"), requests
            assert len(list((temp / "md-render/images").iterdir())) == 3, "failed download left cache/staging output"
            assert len(list((temp / "md-render/plantuml").iterdir())) == 1, "diagram staging output leaked"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("Download integration: literal URLs, ignored curlrc, protocol rejection, atomic publication, and PlantUML passed")


if __name__ == "__main__":
    main()
