--- @since 26.1.22
local M = {}

local current = ya.sync(function()
  local hovered = cx.active.current.hovered
  local skip = tonumber(cx.active.preview.skip) or 0
  return hovered and hovered.url or nil, skip
end)

local ok_common, C = pcall(require, "obsidian-common")
if not ok_common then
  ya.notify({ title = "Obsidian Tune", content = "Missing obsidian-common plugin. Run install.sh to fix.", timeout = 5, level = "error" })
  return M
end

local clamp = C.clamp

local function default_zoom()
  return C.clamp_tuning(C.env("OBSIDIAN_YAZI_READABILITY_ZOOM", "1.00"), 1.00)
end

local function tune_step()
  local n = tonumber(C.env("OBSIDIAN_YAZI_TUNE_STEP", "0.06"))
  if not n then
    return 0.06
  end
  return clamp(0.01, n, 0.50)
end

local function effective_tune_step(action, zoom)
  local step = tune_step()
  if action == "zoom-in" or action == "zoom-out" then
    -- Keep tiny increments from becoming visually invisible in split panes.
    step = math.max(step, 0.07)
    if tonumber(zoom) and tonumber(zoom) >= 1.60 then
      step = math.min(0.18, step * 1.15)
    end
  end
  return step
end

local function tune_fast_mode_enabled()
  return C.env("OBSIDIAN_YAZI_TUNE_FAST_MODE", "1") ~= "0"
end


local function tuning_file(root)
  return root .. "/mode/.live-tuning.json"
end

local function read_tuning(path, fallback_zoom)
  if not fs.cha(Url(path)) then
    return fallback_zoom
  end

  local raw = C.run_capture("jq", {
    "-r",
    '.readabilityZoom // ""',
    path,
  })
  if not raw then
    return fallback_zoom
  end

  local zoom_raw = raw:match("([^\r\n]*)")
  local zoom = C.clamp_tuning(zoom_raw, fallback_zoom)
  return zoom
end

local function save_tuning(path, zoom)
  local payload = string.format(
    '{"readabilityZoom":%.3f,"updatedAt":%d}\n',
    zoom,
    os.time()
  )
  return C.atomic_write_file(path, payload)
end

local function has_value_changed(before_v, after_v)
  return math.abs((before_v or 0) - (after_v or 0)) > 0.0005
end

local function limit_message(action)
  if action == "zoom-in" then
    return "Cannot increase text size any further (max reached)."
  elseif action == "zoom-out" then
    return "Cannot decrease text size any further (min reached)."
  elseif action == "reset" then
    return "Already reset."
  elseif action == "legacy-auto" then
    return "Page height/profile tuning is now automatic."
  end
  return "No changes were applied."
end

local function action_message(action)
  if action == "zoom-in" then
    return "Increased text size."
  elseif action == "zoom-out" then
    return "Decreased text size."
  elseif action == "reset" then
    return "Reset live tuning."
  elseif action == "legacy-auto" then
    return "Automatic page-fit/profile mode is active."
  end
  return "Current live tuning values."
end

function M:entry(job)
  local action = job.args and job.args[1] or "show"
  local hovered_url, skip = current()

  local root = C.cache_root()
  if not C.is_safe_cache_root(root) then
    ya.notify({
      title = "Obsidian Preview Tuning",
      content = "Invalid cache root: " .. tostring(root),
      timeout = 2.2,
      level = "warn",
    })
    return
  end
  C.ensure_mode_dir(root)

  local base_zoom = default_zoom()
  local path = tuning_file(root)
  local zoom = read_tuning(path, base_zoom)
  local before_zoom = zoom
  local used_step = 0

  local changed = false
  local status_action = action
  if action == "zoom-in" then
    used_step = effective_tune_step(action, zoom)
    zoom = C.clamp_tuning(zoom + used_step, zoom)
    changed = true
  elseif action == "zoom-out" then
    used_step = effective_tune_step(action, zoom)
    zoom = C.clamp_tuning(zoom - used_step, zoom)
    changed = true
  elseif action == "reset" then
    zoom = base_zoom
    changed = true
  elseif ({ ["tall-in"]=1, ["tall-out"]=1, ["profile-next"]=1, ["profile-auto"]=1, ["profile-fast"]=1, ["profile-balanced"]=1, ["profile-quality"]=1 })[action] then
    status_action = "legacy-auto"
  elseif action ~= "show" then
    ya.notify({
      title = "Obsidian Preview Tuning",
      content = "Unknown action. Use zoom-in, zoom-out, reset, or show.",
      timeout = 2.0,
      level = "warn",
    })
    return
  end

  local changed_effectively = has_value_changed(before_zoom, zoom)
  if changed and changed_effectively then
    local ok, err = save_tuning(path, zoom)
    if not ok then
      ya.notify({
        title = "Obsidian Preview Tuning",
        content = "Failed to save live tuning: " .. tostring(err),
        timeout = 2.2,
        level = "warn",
      })
      return
    end
  end

  if hovered_url then
    local fast_mode = changed_effectively and tune_fast_mode_enabled()
    ya.emit("peek", {
      math.max(0, skip or 0),
      only_if = hovered_url,
      force_regen = changed_effectively,
      fast_mode = fast_mode,
      tune_zoom = zoom,
      tune_action = status_action,
    })
  end

  local status
  local level = "info"
  if status_action == "show" then
    status = action_message(status_action)
  elseif changed_effectively then
    if hovered_url then
      status = action_message(status_action) .. " (regenerating preview...)"
    else
      status = action_message(status_action) .. " (saved only; applied on next preview)"
    end
  else
    status = limit_message(status_action)
    level = "warn"
  end

  ya.notify({
    title = "Obsidian Preview Tuning",
    content = string.format(
      "%s | Zoom %.2fx%s | Page-fit/profile: auto",
      status,
      zoom,
      used_step > 0 and string.format(" | Step %.2f", used_step) or ""
    ),
    timeout = 2.2,
    level = level,
  })
end

return M
