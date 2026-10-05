"""Exercise real curl downloads and cross-process cache cleanup on loopback only."""

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
            data = {
                "/broken.png": b"not an image",
                "/truncated.jpg": bytes.fromhex("FFD8FFC0001108000C002203"),
            }.get(self.path, png)
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
            source, local_image = temp / "source.puml", temp / "local.png"
            source.write_text("@startuml\nAlice -> Bob\n@enduml")
            local_image.write_bytes(png)
            originals = {path: path.read_bytes() for path in (source, local_image)}
            runner = temp / "check.lua"
            runner.write_text(r'''
local config = vim.json.decode(assert(os.getenv "MD_RENDER_SECURITY_CONFIG"))
package.path = config.repo .. "/lua/?.lua;" .. config.repo .. "/lua/?/init.lua;" .. package.path
local real_system, codes = vim.system, {}
vim.system = function(cmd, opts, callback)
  return real_system(cmd, opts, function(result)
    codes[#codes + 1] = result.code
    callback(result)
  end)
end
local image = require "md-render.image"
if config.phase ~= "populate" then
  assert((image.get_cached(config.base .. "/ordinary.png") ~= nil) == (config.phase == "reuse"), "unexpected download cache state")
end
local names = config.phase == "populate"
  and { "/ordinary.png", "/brace{a,b}.png", "/bracket[1-3].png", "/redirect", "/broken.png", "/partial.png", "/truncated.jpg" }
  or { "/ordinary.png" }
for _, name in ipairs(names) do
  local done, output = false, nil
  image.download_async(config.base .. name, function(path) done, output = true, path end)
  assert(vim.wait(20000, function() return done end), "download timed out: " .. name)
  local success = name == "/ordinary.png" or name == "/brace{a,b}.png" or name == "/bracket[1-3].png"
  assert((output ~= nil) == success, "unexpected result: " .. name)
  if success then assert(image.image_dimensions(output) == 4) end
  if name == "/redirect" then assert(codes[#codes] == 1, "redirect was not rejected as a forbidden protocol") end
  if name == "/truncated.jpg" then
    assert(codes[#codes] == 0, "JPEG rejection must follow a complete HTTP transfer")
    assert(not image.get_cached(config.base .. name), "truncated JPEG entered the cache")
  end
end
local executable = vim.fn.executable
vim.fn.executable = function(name) return (name == "plantuml" or name == "java") and 0 or executable(name) end
image.reset_cache()
image.setup { plantuml_server = config.base .. "/plantuml" }
local source = table.concat(vim.fn.readfile(config.source), "\n")
assert((image.get_plantuml_cached(source) ~= nil) == (config.phase == "reuse"), "unexpected diagram cache state")
local done, output = false, nil
image.render_plantuml_async(source, function(path) done, output = true, path end)
assert(vim.wait(20000, function() return done end) and output, "remote PlantUML download failed")
assert(image.image_dimensions(output) == 4)
vim.fn.writefile({ vim.json.encode {
  cache_dir = image.cache_dir(),
  download = image.get_cached(config.base .. "/ordinary.png"),
  diagram = output,
} }, config.result)
''')
            env = os.environ | {
                "XDG_CONFIG_HOME": str(temp / "xdg-config"),
                "XDG_DATA_HOME": str(temp / "xdg-data"),
                "XDG_CACHE_HOME": str(temp / "xdg-cache"),
                "XDG_STATE_HOME": str(temp / "xdg-state"),
                "NVIM_LOG_FILE": str(temp / "nvim.log"),
                "CURL_HOME": str(temp),
            }
            def run(phase):
                env["MD_RENDER_SECURITY_CONFIG"] = json.dumps({
                    "repo": str(repo), "base": base, "source": str(source),
                    "phase": phase, "result": str(temp / "result.json"),
                })
                result = subprocess.run(
                    ["nvim", "-n", "-i", "NONE", "--headless", "-u", "NONE", "--noplugin", "-l", str(runner)],
                    cwd=repo, env=env, capture_output=True, text=True, timeout=60,
                )
                assert result.returncode == 0, result.stdout + result.stderr
                assert all(path.read_bytes() == data for path, data in originals.items()), "source/local media changed"
                return json.loads((temp / "result.json").read_text())

            populated = run("populate")
            assert requests[:7] == [
                "/ordinary.png", "/brace{a,b}.png", "/bracket[1-3].png", "/redirect", "/broken.png", "/partial.png", "/truncated.jpg",
            ], requests
            assert len(requests) == 8 and requests[7].startswith("/plantuml/png/~h"), requests
            cache_dir = Path(populated["cache_dir"])
            assert cache_dir.name == "md-render" and cache_dir.is_relative_to(temp / "xdg-cache"), cache_dir
            assert len(list((cache_dir / "images").iterdir())) == 3, "failed download left cache/staging output"
            assert len(list((cache_dir / "plantuml").iterdir())) == 1, "diagram staging output leaked"
            assert run("reuse") == populated, "fresh process did not reuse the same cache files"
            assert len(requests) == 8, "cache reuse made new HTTP requests"

            # Every Neovim worker and its awaited producers have exited before removal.
            shutil.rmtree(cache_dir)
            assert not cache_dir.exists()
            assert all(path.read_bytes() == data for path, data in originals.items()), "purge changed source/local media"
            assert run("rebuild") == populated, "fresh process did not rebuild the same cache entries"
            assert requests[8:] == ["/ordinary.png", requests[7]], requests
            print(f"Media cache lifecycle: {cache_dir}; reuse without HTTP, purge after exit, and rebuild passed")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("Download integration: literal URLs, ignored curlrc, protocol rejection, atomic publication, and PlantUML passed")


if __name__ == "__main__":
    main()
