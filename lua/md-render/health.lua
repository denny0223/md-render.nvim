local M = {}

function M.check()
  local health = vim.health
  local image = require "md-render.image"
  local text_size = require "md-render.text_size"
  local config = image.config()
  health.start "md-render"
  if vim.fn.has "nvim-0.12" == 1 then
    health.ok "Neovim supports terminal rendering (0.12+)"
  else
    health.error "Neovim 0.12 or newer is required"
  end
  health.info("Image backend: " .. config.backend)
  health.info("Autoplay: " .. tostring(config.autoplay ~= false))
  health.info("Mermaid npx fallback: " .. tostring(config.mermaid_allow_npx ~= false))

  local function tool(name, purpose)
    if vim.fn.executable(name) == 1 then
      health.ok(name .. ": " .. purpose)
      return true
    end
    health.warn(name .. " unavailable; " .. purpose)
    return false
  end

  tool("curl", "downloads web images and videos")
  tool("ffmpeg", "extracts GIF and video frames")
  tool("ffprobe", "reads video dimensions")
  tool("magick", "optional for native inline images; required for Snacks conversion and image-tab zoom/pan")
  if config.backend == "snacks" then
    if pcall(require, "snacks.image") then
      health.ok "Snacks image module is available; :checkhealth snacks reports its requirements"
    else
      health.error "Snacks image backend selected, but snacks.image is unavailable"
    end
  end
  if vim.fn.executable "mmdc" == 1 then
    health.ok "Mermaid CLI is installed; rendering also requires its browser"
  elseif config.mermaid_allow_npx ~= false and vim.fn.executable "npx" == 1 then
    health.info "Mermaid may download and run its CLI through npx; a browser is still required"
  else
    health.info "Mermaid CLI unavailable; diagrams retain their code blocks"
  end
  health.info(image.has_plantuml() and "PlantUML renderer or server is configured" or "PlantUML retains code blocks")

  health.start "Headings and terminal"
  if #vim.api.nvim_list_uis() > 0 then
    local ok, supported = pcall(image.supports_kitty)
    if ok and supported then
      health.ok "Selected image backend reports terminal support"
    else
      health.warn "Image backend unavailable; ordinary Markdown remains readable"
    end
    health.info("Heading status: " .. text_size.status())
  else
    health.info "No attached UI; terminal capabilities have not been checked"
  end
  local heading = text_size.config()
  if heading.enabled and heading.backend ~= "native" then
    local ok, result = pcall(function()
      return vim
        .system({
          heading.image.python,
          "-c",
          "import gi, cairo; gi.require_version('Pango', '1.0'); gi.require_version('PangoCairo', '1.0'); from gi.repository import Pango, PangoCairo",
        }, { text = true, timeout = 5000 })
        :wait()
    end)
    if ok and result.code == 0 then
      health.ok "Python, PyGObject, Pycairo and Pango are available for image headings"
    else
      health.warn "Image-heading Python dependencies unavailable; install PyGObject, Pycairo and Pango on the Neovim host"
    end
  end
  if vim.env.TMUX then health.info "Inside tmux; heading status reports capability and focus restrictions" end
  health.info("Media cache: " .. image.cache_dir())
  health.info "Verify a local image and heading in a preview; dependency checks do not establish correct terminal display"
end

return M
