--- @since 26.1.22
local M = {}

local current = ya.sync(function()
  local hovered = cx.active.current.hovered
  local skip = cx.active.preview.skip
  return hovered and hovered.url or nil, skip
end)

local ok_common, C = pcall(require, "obsidian-common")
if not ok_common then
  ya.notify({ title = "Obsidian Toggle", content = "Missing obsidian-common plugin. Run install.sh to fix.", timeout = 5, level = "error" })
  return M
end

function M:entry()
  local hovered_url, skip = current()
  if not hovered_url then
    return
  end

  local abs_path = C.to_path(hovered_url)
  if not abs_path:lower():match("%.md$") then
    return
  end

  local rel = C.relpath(abs_path, C.vault_root())
  if not rel then
    ya.notify({
      title = "Obsidian Preview",
      content = "Cannot toggle: file is outside the Vault.",
      timeout = 2,
      level = "warn",
    })
    return
  end

  local digest = C.md5_hex(rel)
  local root = C.cache_root()
  if not C.is_safe_cache_root(root) then
    ya.notify({
      title = "Obsidian Preview",
      content = "Invalid cache root: " .. tostring(root),
      timeout = 2.0,
      level = "warn",
    })
    return
  end
  C.ensure_mode_dir(root)

  local mode_url = C.mode_path(root, digest)
  if fs.cha(mode_url) then
    fs.remove("file", mode_url)
    ya.notify({
      title = "Obsidian Preview",
      content = "Switched to PNG preview.",
      timeout = 1.5,
      level = "info",
    })
  else
    fs.write(mode_url, "markdown\n")
    ya.notify({
      title = "Obsidian Preview",
      content = "Switched to Markdown preview.",
      timeout = 1.5,
      level = "info",
    })
  end

  ya.emit("peek", { math.max(0, skip or 0), only_if = hovered_url })
end

return M
