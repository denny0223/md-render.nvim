---@class MdRender.TabWin
---@field private augroup string
---@field private win? integer
local TabWin = {}

---@param augroup_name? string
TabWin.new = function(augroup_name)
  return setmetatable({ augroup = augroup_name or "md_render_tab" }, { __index = TabWin })
end

function TabWin:setup(win)
  self.win = win
  local augroup = vim.api.nvim_create_augroup(self.augroup, { clear = true })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = augroup,
    callback = function()
      -- Only act if we're leaving the preview tab
      if vim.api.nvim_get_current_win() == self.win then
        vim.schedule(function()
          if self.win == win then self:close_if_valid() end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      self:close_if_valid()
    end,
  })
end

---@return boolean
function TabWin:close_if_valid()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local win = self.win
    self:detach()
    vim.api.nvim_win_close(win, true)
    return true
  end
  self:detach()
  return false
end

function TabWin:detach()
  self.win = nil
  pcall(vim.api.nvim_del_augroup_by_name, self.augroup)
end

return TabWin
