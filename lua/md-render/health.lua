local M = {}
-- Python -c searches its cwd for imports; keep document-side modules out of the probe.
local probe_cwd = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

function M.check()
  local health = vim.health
  health.start "md-render"
  if vim.fn.has "nvim-0.12" == 1 then
    health.ok "Neovim supports terminal rendering (0.12+)"
  else
    health.error("Neovim 0.12+ required (running " .. tostring(vim.version()) .. "); upgrade Neovim and restart")
    return
  end
  local image = require "md-render.image"
  local text_size = require "md-render.text_size"
  local config = image.config()
  health.info("Image backend: " .. config.backend)
  health.info("Autoplay: " .. tostring(config.autoplay ~= false))
  health.info("Mermaid npx fallback: " .. tostring(config.mermaid_allow_npx ~= false))

  health.start "Optional media tools (ordinary Markdown needs none of these)"
  local function tool(name, purpose, package)
    if vim.fn.executable(name) == 1 then
      health.ok(name .. " (" .. vim.fn.exepath(name) .. "): " .. purpose)
      return true
    end
    health.warn(name .. " unavailable; " .. purpose .. "; install " .. (package or name) .. " on Neovim's PATH")
    return false
  end

  tool("curl", "downloads web images and videos")
  tool("ffmpeg", "converts native images and extracts GIF/video frames", "FFmpeg")
  tool("ffprobe", "reads video dimensions", "FFmpeg")
  tool(
    "magick",
    "required for Snacks conversion and image-tab zoom/pan; native images may use ffmpeg/sips",
    "ImageMagick 7 (convert alone is insufficient)"
  )
  -- Snacks lazily requires modules through __index; health must not load them.
  local snacks_loaded = type(_G.Snacks) == "table" and rawget(_G.Snacks, "image")
  if config.backend == "snacks" then
    if snacks_loaded then
      health.ok "Snacks image module is available; :checkhealth snacks reports its requirements"
    else
      health.error 'Snacks backend selected but Snacks.image is not loaded; install snacks.nvim and configure image.enabled = true before opening previews, or select backend = "kitty"'
    end
  end
  if vim.fn.executable "mmdc" == 1 then
    health.ok("Mermaid CLI (" .. vim.fn.exepath "mmdc" .. ") is installed; browser availability has not been checked")
  elseif config.mermaid_allow_npx ~= false and vim.fn.executable "npx" == 1 then
    health.info "Mermaid may download and run its CLI through npx; a browser is still required"
  else
    local _, reason = image.has_mmdc()
    health.info(
      (reason or "Mermaid detection is cached; restart Neovim to refresh") .. "; diagrams retain their code blocks"
    )
  end
  local plantuml, reason = image.has_plantuml()
  if plantuml then
    health.info(reason)
  elseif vim.fn.executable "plantuml" == 1 or vim.env.PLANTUML_JAR or config.plantuml_server then
    health.warn(reason .. "; diagrams retain their code blocks")
  else
    health.info(reason .. "; diagrams retain their code blocks")
  end

  health.start "Headings and terminal"
  if #vim.api.nvim_list_uis() > 0 then
    local ok, supported = false, false
    if config.backend ~= "snacks" or snacks_loaded then
      ok, supported = pcall(image.supports_kitty)
    end
    if ok and supported then
      health.ok "Selected image backend reports terminal support"
    else
      health.warn "Image backend unavailable; ordinary Markdown remains readable; check the terminal requirements in :help md-render-requirements (Snacks also needs :checkhealth snacks)"
    end
    local status_ok, status = pcall(text_size.status)
    if status_ok then
      health.info("Heading status: " .. status)
    else
      health.warn("Heading status check failed; use :MdRender textsize off for ordinary headings; " .. tostring(status))
    end
  else
    health.info "No attached UI; terminal capabilities have not been checked"
  end
  local heading = text_size.config()
  if heading.enabled and heading.backend ~= "native" then
    local probe =
      "import gi, cairo; gi.require_version('Pango', '1.0'); gi.require_version('PangoCairo', '1.0'); from gi.repository import Pango, PangoCairo"
    if heading.image.font_size == "auto" then
      probe = probe
        .. "; assert hasattr(Pango.FontMetrics, 'get_height'), 'automatic font size requires Pango 1.44+; upgrade Pango'"
    end
    local ok, result = pcall(function()
      local python = vim.fn.exepath(heading.image.python)
      if python == "" then python = heading.image.python end
      return vim.system({ python, "-c", probe }, { text = true, timeout = 5000, cwd = probe_cwd }):wait()
    end)
    if ok and result.code == 0 then
      health.ok "Python, PyGObject, Pycairo and Pango are available for image headings"
    else
      local detail
      if not ok then
        detail = tostring(result)
      elseif result.code == 124 then
        detail = "dependency probe timed out after 5000 ms"
      else
        detail = (result.stderr or ""):match "([^\r\n]+)[\r\n]*$" or "dependency probe exited " .. result.code
      end
      health.warn(
        "Image headings unavailable with "
          .. heading.image.python
          .. "; install/upgrade PyGObject, Pycairo and Pango on the Neovim host; "
          .. detail
      )
    end
  end
  if vim.env.TMUX then health.info "Inside tmux; heading status reports capability and focus restrictions" end
  health.info("Media cache: " .. image.cache_dir())
  health.info "After installing or upgrading tools, restart Neovim and reopen the preview; detections are cached"
  health.info "Verify a local image and heading in a preview; dependency checks do not establish correct terminal display"
end

return M
