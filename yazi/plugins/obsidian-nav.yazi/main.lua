--- @since 26.1.22
local M = {}

local current = ya.sync(function()
  local hovered = cx.active.current.hovered
  local skip = tonumber(cx.active.preview.skip) or 0
  return hovered and hovered.url or nil, skip
end)

M._meta = {}
M._notice = {
  at = 0,
  text = "",
}

local ok_common, C = pcall(require, "obsidian-common")
if not ok_common then
  ya.notify({ title = "Obsidian Nav", content = "Missing obsidian-common plugin. Run install.sh to fix.", timeout = 5, level = "error" })
  return M
end

local NAV_META_MAX = 64

local function prune_nav_meta()
  local count = 0
  for _ in pairs(M._meta) do
    count = count + 1
  end
  if count <= NAV_META_MAX then
    return
  end
  local entries = {}
  for k, v in pairs(M._meta) do
    entries[#entries + 1] = { key = k, at = tonumber(v.at or 0) or 0 }
  end
  table.sort(entries, function(a, b) return a.at < b.at end)
  for i = 1, count - NAV_META_MAX do
    M._meta[entries[i].key] = nil
  end
end

local function context_for(url)
  local rel = C.relpath(C.to_path(url), C.vault_root())
  if not rel then
    return nil
  end
  return {
    root = C.cache_root(),
    digest = C.md5_hex(rel),
  }
end

local function fallback_seek(direction)
  ya.emit("seek", { direction > 0 and 5 or -5 })
end

local function nav_notice(text, level, timeout)
  if not C.is_true(C.env("OBSIDIAN_YAZI_NAV_NOTIFY", "0")) then
    return
  end
  local now = C.now_seconds()
  local prev = M._notice or { at = 0, text = "" }
  if prev.text == text and (now - (prev.at or 0)) < 1.2 then
    return
  end
  M._notice = { at = now, text = text }
  ya.notify({
    title = "Obsidian Nav",
    content = text,
    timeout = timeout or 1.2,
    level = level or "info",
  })
end

local function read_page_count(root, digest)
  local meta_url = C.meta_path(root, digest)
  local cha = fs.cha(meta_url)
  local key = tostring(meta_url)
  if not cha then
    M._meta[key] = nil
    return nil
  end

  local mtime = cha.mtime or 0
  local cached = M._meta[key]
  if cached and cached.mtime == mtime then
    cached.at = C.now_seconds()
    return cached.page_count
  end

  local raw = C.run_capture("jq", {
    "-r",
    ".pageCount // 0",
    key,
  })
  if not raw then
    return nil
  end

  local count = tonumber((raw:gsub("%s+$", "")))
  if not count or count <= 0 then
    M._meta[key] = { mtime = mtime, page_count = nil, at = C.now_seconds() }
    prune_nav_meta()
    return nil
  end

  local page_count = math.floor(count)
  M._meta[key] = { mtime = mtime, page_count = page_count, at = C.now_seconds() }
  prune_nav_meta()
  return page_count
end

function M:entry(job)
  local direction = (job.args and job.args[1] == "prev") and -1 or 1
  local hovered_url, skip = current()
  if not hovered_url then
    return
  end

  local abs_path = C.to_path(hovered_url)
  if not abs_path:lower():match("%.md$") then
    return fallback_seek(direction)
  end

  local ctx = context_for(hovered_url)
  if not ctx then
    return fallback_seek(direction)
  end

  if fs.cha(C.mode_path(ctx.root, ctx.digest)) then
    return fallback_seek(direction)
  end

  if not fs.cha(C.page_img_path(ctx.root, ctx.digest, 0)) then
    nav_notice("Preview pages are preparing automatically...", "info", 1.2)
    ya.emit("peek", {
      0,
      only_if = hovered_url,
    })
    return
  end

  local current_page = math.max(0, tonumber(skip) or 0)
  local target_page = current_page + direction
  if target_page < 0 then
    nav_notice("Already at the first page.", "info", 0.9)
    return
  end

  local page_count = read_page_count(ctx.root, ctx.digest)
  if page_count and page_count > 0 and target_page >= page_count then
    nav_notice("Already at the last page.", "info", 0.9)
    return
  end

  ya.emit("peek", { target_page, only_if = hovered_url })
end

return M
