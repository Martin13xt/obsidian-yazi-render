--- @since 26.1.22
local M = {}

local current = ya.sync(function()
  local hovered = cx.active.current.hovered
  return hovered and hovered.url or nil
end)

local ok_common, C = pcall(require, "obsidian-common")
if not ok_common then
  ya.notify({ title = "Obsidian Refresh", content = "Missing obsidian-common plugin. Run install.sh to fix.", timeout = 5, level = "error" })
  return M
end

local function clear_note_state_for_refresh(root, digest)
  -- Keep existing PNG pages during refresh so preview does not fall back to Markdown.
  -- Removing meta forces stale-detection and triggers regeneration on the next peek.
  C.safe_remove_file(C.meta_path(root, digest))
  C.safe_remove_file(C.mode_path(root, digest))
  C.safe_remove_file(Url(root .. "/locks/" .. digest .. ".lock"))
  C.safe_remove_file(Url(root .. "/log/" .. digest .. ".status.json"))
  C.safe_remove_file(Url(root .. "/log/" .. digest .. ".json"))
  C.safe_remove_file(Url(root .. "/log/" .. digest .. ".error.json"))
end

function M:entry()
  local hovered_url = current()
  if not hovered_url then
    return
  end

  local abs_path = C.to_path(hovered_url)
  if not abs_path:lower():match("%.md$") then
    ya.notify({
      title = "Obsidian Preview",
      content = "Run this on a Markdown note.",
      timeout = 1.5,
      level = "warn",
    })
    return
  end

  local rel = C.relpath(abs_path, C.vault_root())
  if not rel then
    ya.notify({
      title = "Obsidian Preview",
      content = "Cannot regenerate: file is outside the Vault.",
      timeout = 2,
      level = "warn",
    })
    return
  end

  local digest = C.md5_hex(rel)
  local root = C.cache_root()
  local ok_cache, cache_err = C.ensure_cache_dirs(root)
  if not ok_cache then
    ya.notify({
      title = "Obsidian Preview",
      content = "Invalid cache root: " .. tostring(cache_err),
      timeout = 2.2,
      level = "warn",
    })
    return
  end
  clear_note_state_for_refresh(root, digest)

  -- Write polling marker so preview plugin enters polling loop on next peek.
  -- This marker persists until render completes (survives peek restarts from touch).
  local marker_path = root .. "/locks/" .. digest .. ".regen_polling"
  C.atomic_write_file(marker_path, tostring(os.time()) .. "\n")

  -- Touch the file to change mtime, triggering yazi's directory watcher to re-peek.
  -- The preview plugin detects .regen_polling marker and enters polling loop with progress.
  local touch_child = Command("touch"):arg(abs_path):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
  if touch_child then touch_child:wait_with_output() end
end

return M
