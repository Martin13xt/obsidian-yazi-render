--- @since 26.1.22
local M = {}
M._cache_dirs_ready_for = nil
M._meta_cache = {}
M._refresh_state = {}
M._tuning_cache = {}
M._status_cache = {}
M._digest_cache = {}
M._request_error_state = {}
M._rest_fallback_notice_at = 0
M._runtime_path_checked = false
M._rest_auth_cache = {}
M._rest_settings_scan_cache = nil
M._cache_repair_notice_state = {}
M._manual_refresh_pending = {}
M._transport_backoff_until = {}
M._layout_stability = {}

local ok_common, C = pcall(require, "obsidian-common")
if not ok_common then
  ya.notify({ title = "Obsidian Preview", content = "Missing obsidian-common plugin. Run install.sh to fix.", timeout = 5, level = "error" })
  return M
end

local env = C.env
local is_true = C.is_true
local is_truthy = C.is_truthy
local to_int = C.to_int
local clamp = C.clamp
local json_string = C.json_string
local safe_remove_file = C.safe_remove_file
local run_capture = C.run_capture
local short_text = C.short_text

local function vault_name()
  return env("OBSIDIAN_VAULT_NAME", "obsidian")
end

local function command_id()
  return env("OBSIDIAN_YAZI_COMMANDID", "yazi-exporter:export-requested-to-cache")
end

local function uri_scheme()
  return env("OBSIDIAN_URI_SCHEME", "obsidian://adv-uri")
end

local function use_rest()
  return is_true(env("OBSIDIAN_YAZI_USE_REST", "1"))
end

local function cli_fallback()
  -- Keep disabled by default: Obsidian CLI can launch/focus the app depending on runtime state.
  return is_true(env("OBSIDIAN_YAZI_CLI_FALLBACK", "0"))
end

local function auto_cli_fallback()
  -- Keep disabled by default and enable explicitly after validating local UX.
  return is_true(env("OBSIDIAN_YAZI_AUTO_CLI_FALLBACK", "0"))
end

local function cli_bin_candidates()
  local configured = env("OBSIDIAN_YAZI_CLI_BIN", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if configured ~= "" then
    return { configured }
  end
  return { "obsidian", "Obsidian.com" }
end

local function uri_fallback()
  -- Keep URI fallback opt-in: opening obsidian:// can steal focus during browsing.
  return is_true(env("OBSIDIAN_YAZI_URI_FALLBACK", "0"))
end

local function auto_uri_fallback()
  -- Keep disabled by default to avoid unexpected app focus changes.
  return is_true(env("OBSIDIAN_YAZI_AUTO_URI_FALLBACK", "0"))
end

local function allow_remote_rest()
  return is_true(env("OBSIDIAN_REST_ALLOW_REMOTE", "0"))
end

local function prefer_env_api_key()
  return is_true(env("OBSIDIAN_YAZI_PREFER_ENV_API_KEY", "0"))
end

local function allow_home_key_scan()
  -- Disabled by default: scanning other vault settings under $HOME can cross trust boundaries.
  return is_true(env("OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN", "0"))
end

local function verify_tls_certs(host)
  local raw = env("OBSIDIAN_REST_VERIFY_TLS", "")
  if raw == "" then
    local h = tostring(host or ""):lower()
    return not (h == "127.0.0.1" or h == "localhost" or h == "::1")
  end
  return is_true(raw)
end

local function rest_connect_timeout_secs()
  return clamp(1, to_int(env("OBSIDIAN_REST_CONNECT_TIMEOUT_SECS", "1"), 1), 30)
end

local function rest_max_time_secs()
  return clamp(rest_connect_timeout_secs(), to_int(env("OBSIDIAN_REST_MAX_TIME_SECS", "3"), 3), 60)
end

local function open_background()
  return is_true(env("OBSIDIAN_OPEN_BACKGROUND", "1"))
end

local function ttl_seconds()
  return to_int(env("OBSIDIAN_YAZI_TTL_DAYS", "3"), 3) * 24 * 60 * 60
end

local function lock_seconds()
  return to_int(env("OBSIDIAN_YAZI_LOCK_SECS", "90"), 90)
end

local function show_stale_image()
  return is_true(env("OBSIDIAN_YAZI_SHOW_STALE_IMAGE", "1"))
end

local function show_refresh_notify()
  return is_true(env("OBSIDIAN_YAZI_REFRESH_NOTIFY", "0"))
end

local function verbose_refresh_notify()
  return is_true(env("OBSIDIAN_YAZI_REFRESH_NOTIFY_VERBOSE", "0"))
end

local function show_cache_repair_notify()
  return is_true(env("OBSIDIAN_YAZI_CACHE_REPAIR_NOTIFY", "0"))
end

local function refresh_poll_secs()
  local raw = tonumber(env("OBSIDIAN_YAZI_REFRESH_POLL_SECS", "0.40"))
  if not raw then
    return 0.40
  end
  return math.max(0.18, math.min(1.6, raw))
end

local function refresh_md_poll_secs()
  local raw = tonumber(env("OBSIDIAN_YAZI_REFRESH_MD_POLL_SECS", "1.00"))
  if not raw then
    return 1.00
  end
  return math.max(0.40, math.min(3.0, raw))
end

local function lock_quick_retry_secs()
  return clamp(2, to_int(env("OBSIDIAN_YAZI_LOCK_QUICK_RETRY_SECS", "10"), 10), 30)
end

local function progress_notify_interval_secs()
  local raw = tonumber(env("OBSIDIAN_YAZI_PROGRESS_NOTIFY_SECS", "1.2"))
  if not raw then
    return 1.2
  end
  return math.max(0.4, math.min(5.0, raw))
end

local function layout_settle_secs()
  local raw = tonumber(env("OBSIDIAN_YAZI_LAYOUT_SETTLE_SECS", "1.0"))
  if not raw then
    return 1.0
  end
  return math.max(0.2, math.min(5.0, raw))
end

local function transport_retry_backoff_secs()
  local raw = tonumber(env("OBSIDIAN_YAZI_TRANSPORT_RETRY_SECS", "4.0"))
  if not raw then
    return 4.0
  end
  return math.max(1.0, math.min(20.0, raw))
end

local function queue_max_files()
  return clamp(8, to_int(env("OBSIDIAN_YAZI_QUEUE_MAX_FILES", "16"), 16), 256)
end

local function base_render_width_px()
  return to_int(env("OBSIDIAN_YAZI_BASE_WIDTH_PX", "640"), 640)
end

local function readability_zoom()
  local raw = tonumber(env("OBSIDIAN_YAZI_READABILITY_ZOOM", "1.00"))
  if not raw then
    return 1.00
  end
  return math.max(0.70, math.min(2.40, raw))
end

local function base_preview_cols()
  return math.max(20, to_int(env("OBSIDIAN_YAZI_BASE_COLS", "80"), 80))
end

local function render_px_per_col()
  return math.max(4, to_int(env("OBSIDIAN_YAZI_PX_PER_COL", "9"), 9))
end

local function terminal_program_name()
  local term_program = tostring(os.getenv("TERM_PROGRAM") or ""):lower()
  if term_program ~= "" then
    return term_program
  end

  local wezterm_pane = tostring(os.getenv("WEZTERM_PANE") or "")
  if wezterm_pane ~= "" then
    return "wezterm"
  end

  local warp_session = tostring(os.getenv("WARP_IS_LOCAL_SHELL_SESSION") or "")
  if warp_session ~= "" then
    return "warp"
  end

  local term = tostring(os.getenv("TERM") or ""):lower()
  if term:find("wezterm", 1, true) then
    return "wezterm"
  end
  if term:find("warp", 1, true) then
    return "warp"
  end

  return ""
end

local function parse_render_scale(raw, fallback)
  local n = tonumber(raw)
  if not n then
    return fallback
  end
  return clamp(0.70, n, 2.60)
end

local function render_width_terminal_scale()
  local global_raw = env("OBSIDIAN_YAZI_RENDER_SCALE", "")
  if global_raw ~= "" then
    return parse_render_scale(global_raw, 1.00)
  end

  local term_program = terminal_program_name()
  if term_program:find("wezterm", 1, true) then
    -- Small boost to ensure canvas pixels cover WezTerm's cell width on high-DPI.
    local wez_raw = env("OBSIDIAN_YAZI_RENDER_SCALE_WEZTERM", "1.06")
    return parse_render_scale(wez_raw, 1.06)
  end

  if term_program:find("warp", 1, true) then
    local warp_raw = env("OBSIDIAN_YAZI_RENDER_SCALE_WARP", "")
    return parse_render_scale(warp_raw, 1.00)
  end

  if term_program:find("ghostty", 1, true) then
    -- Small boost to ensure canvas pixels cover Ghostty's slightly wider cells.
    local ghostty_raw = env("OBSIDIAN_YAZI_RENDER_SCALE_GHOSTTY", "1.06")
    return parse_render_scale(ghostty_raw, 1.06)
  end

  return 1.00
end

local function min_render_width_px()
  return math.max(280, to_int(env("OBSIDIAN_YAZI_MIN_WIDTH_PX", "420"), 420))
end

local function max_render_width_px()
  return math.max(min_render_width_px(), to_int(env("OBSIDIAN_YAZI_MAX_WIDTH_PX", "2600"), 2600))
end

local function render_width_tolerance_px()
  return math.max(15, to_int(env("OBSIDIAN_YAZI_RENDER_WIDTH_TOLERANCE_PX", "25"), 25))
end

local function dynamic_page_height_enabled()
  return is_true(env("OBSIDIAN_YAZI_DYNAMIC_PAGE_HEIGHT", "1"))
end

local function terminal_cell_aspect_ratio()
  local raw = tonumber(env("OBSIDIAN_YAZI_TERM_CELL_ASPECT", "2.10"))
  if not raw then
    return 2.10
  end
  return math.max(1.0, math.min(3.5, raw))
end

local function page_height_bias()
  local raw = tonumber(env("OBSIDIAN_YAZI_PAGE_HEIGHT_BIAS", "1.00"))
  if not raw then
    return 1.00
  end
  return math.max(0.45, math.min(1.20, raw))
end

local function min_pane_fill_ratio()
  local raw = tonumber(env("OBSIDIAN_YAZI_MIN_PANE_FILL_RATIO", "1.00"))
  if not raw then
    return 1.00
  end
  return math.max(0.50, math.min(1.20, raw))
end

local function page_tallness_scale()
  local raw = tonumber(env("OBSIDIAN_YAZI_PAGE_TALLNESS", "1.00"))
  if not raw then
    return 1.00
  end
  return math.max(0.70, math.min(2.40, raw))
end

local function min_page_ratio()
  local raw = tonumber(env("OBSIDIAN_YAZI_MIN_PAGE_RATIO", "0.90"))
  if not raw then
    return 0.90
  end
  return math.max(0.60, math.min(2.20, raw))
end

local function max_page_ratio()
  local raw = tonumber(env("OBSIDIAN_YAZI_MAX_PAGE_RATIO", "2.80"))
  if not raw then
    return 2.80
  end
  return math.max(min_page_ratio(), math.min(3.60, raw))
end

local function min_page_height_px()
  return math.max(300, to_int(env("OBSIDIAN_YAZI_MIN_PAGE_HEIGHT_PX", "620"), 620))
end

local function max_page_height_px()
  return math.max(min_page_height_px(), to_int(env("OBSIDIAN_YAZI_MAX_PAGE_HEIGHT_PX", "2400"), 2400))
end

local function page_height_tolerance_px()
  return math.max(20, to_int(env("OBSIDIAN_YAZI_PAGE_HEIGHT_TOLERANCE_PX", "40"), 40))
end

local function auto_fit_enabled()
  return is_true(env("OBSIDIAN_YAZI_AUTO_FIT", "1"))
end

local function pane_cols_tolerance()
  return math.max(0, to_int(env("OBSIDIAN_YAZI_PANE_COLS_TOLERANCE", "4"), 4))
end

local function pane_rows_tolerance()
  return math.max(0, to_int(env("OBSIDIAN_YAZI_PANE_ROWS_TOLERANCE", "2"), 2))
end

local function normalize_profile(raw, fallback)
  local value = tostring(raw or ""):lower()
  if value == "fast" or value == "balanced" or value == "quality" or value == "auto" then
    return value
  end
  return fallback or "auto"
end

local function default_render_profile()
  return normalize_profile(env("OBSIDIAN_YAZI_PROFILE", "auto"), "auto")
end

local function auto_profile_enabled()
  return is_true(env("OBSIDIAN_YAZI_AUTO_PROFILE", "1"))
end

local function auto_fast_cols()
  return math.max(30, to_int(env("OBSIDIAN_YAZI_AUTO_FAST_COLS", "120"), 120))
end

local function auto_fast_rows()
  return math.max(10, to_int(env("OBSIDIAN_YAZI_AUTO_FAST_ROWS", "36"), 36))
end

local function auto_quality_cols()
  return math.max(auto_fast_cols() + 20, to_int(env("OBSIDIAN_YAZI_AUTO_QUALITY_COLS", "180"), 180))
end

local function auto_quality_rows()
  return math.max(auto_fast_rows() + 6, to_int(env("OBSIDIAN_YAZI_AUTO_QUALITY_ROWS", "55"), 55))
end

local function in_tmux_session()
  return os.getenv("TMUX") ~= nil and os.getenv("TMUX") ~= ""
end

local function max_mem_cache_entries()
  return math.max(256, to_int(env("OBSIDIAN_YAZI_MAX_MEM_CACHE_ENTRIES", "1200"), 1200))
end

local function readability_width_weight()
  local raw = tonumber(env("OBSIDIAN_YAZI_READABILITY_WIDTH_WEIGHT", "1.30"))
  if not raw then
    return 1.30
  end
  return math.max(0.60, math.min(2.00, raw))
end

local function renderer_main_js()
  return env("OBSIDIAN_YAZI_RENDERER_JS", C.vault_root() .. "/.obsidian/plugins/yazi-exporter/main.js")
end

local function url_encode(raw)
  return (raw:gsub("([^%w%-_%.~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function is_loopback_host(host)
  local h = tostring(host or ""):lower()
  return h == "127.0.0.1" or h == "localhost" or h == "::1"
end

local function cleanup_stale_auth_headers(root)
  local lock_dir = root .. "/locks"
  local keep_mins = math.max(1, math.floor(lock_seconds() / 2))
  local child = Command("find")
    :arg(lock_dir)
    :arg("-type")
    :arg("f")
    :arg("-name")
    :arg(".curl-auth-*.header")
    :arg("-mmin")
    :arg("+" .. tostring(keep_mins))
    :arg("-delete")
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()
  if child then
    child:wait_with_output()
  end
end

local function request_queue_depth(root)
  local queue_dir = root .. "/requests/queue"
  local raw = run_capture("find", {
    queue_dir,
    "-maxdepth", "1",
    "-type", "f",
    "-name", "*.json",
    "-print",
  })
  if not raw or raw == "" then
    return 0
  end

  local count = 0
  for _ in tostring(raw):gmatch("[^\r\n]+") do
    count = count + 1
  end
  return count
end

local function prune_request_queue(root, keep_max, preserve_digest)
  local queue_dir = root .. "/requests/queue"
  local listed = run_capture("ls", {
    "-1t",
    queue_dir,
  })
  if not listed or listed == "" then
    return
  end

  local max_keep = math.max(1, tonumber(keep_max) or queue_max_files())
  local preserve_name = tostring(preserve_digest or "")
  if preserve_name ~= "" then
    preserve_name = preserve_name .. ".json"
  end

  local kept = 0
  for name in tostring(listed):gmatch("[^\r\n]+") do
    if name:match("^[A-Za-z0-9._-]+%.json$") then
      local is_preserve = preserve_name ~= "" and name == preserve_name
      if is_preserve or kept < max_keep then
        kept = kept + 1
      else
        safe_remove_file(queue_dir .. "/" .. name)
      end
    end
  end
end

local function base_img_path(root, digest)
  return Url(root .. "/img/" .. digest .. ".png")
end

local function lock_path(root, digest)
  return Url(root .. "/locks/" .. digest .. ".lock")
end

local function status_path(root, digest)
  return Url(root .. "/log/" .. digest .. ".status.json")
end

local function request_path(root)
  return Url(root .. "/requests/current.txt")
end

local function request_json_path(root)
  return Url(root .. "/requests/current.json")
end

local function request_queue_path(root, digest)
  return Url(root .. "/requests/queue/" .. digest .. ".json")
end

local function tuning_path(root)
  return Url(root .. "/mode/.live-tuning.json")
end

local function new_request_id(rel)
  return ya.hash(rel .. "|" .. tostring(os.time()) .. "|" .. tostring(math.random()))
end

local function write_status_snapshot(root, digest, payload)
  if not root or root == "" or not digest or digest == "" then
    return
  end

  payload = payload or {}
  local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local req_id = tostring(payload.request_id or "")
  local err_message = tostring(payload.error_message or "")
  local status_payload = string.format(
    '{"path":%s,"digest":%s,"requestId":%s,"state":%s,"stage":%s,"updatedAt":%s,"error":%s}\n',
    json_string(tostring(payload.path or "")),
    json_string(tostring(digest)),
    json_string(req_id),
    json_string(tostring(payload.state or "")),
    json_string(tostring(payload.stage or "")),
    json_string(now_iso),
    (err_message ~= "") and json_string(err_message) or "null"
  )
  local status_file = root .. "/log/" .. tostring(digest) .. ".status.json"
  C.atomic_write_file(status_file, status_payload)
end

local read_meta_info

local now_seconds = C.now_seconds

local function prune_lru_cache(cache, max_entries)
  local count = 0
  for _ in pairs(cache) do
    count = count + 1
  end
  if count <= max_entries then
    return
  end

  local entries = {}
  for key, value in pairs(cache) do
    local touched = 0
    if type(value) == "table" then
      touched = tonumber(value.at or value.touched_at or value.mtime or 0) or 0
    end
    entries[#entries + 1] = { key = key, touched = touched }
  end

  table.sort(entries, function(a, b)
    if a.touched == b.touched then
      return tostring(a.key) < tostring(b.key)
    end
    return a.touched < b.touched
  end)

  local overflow = count - max_entries
  for i = 1, overflow do
    local victim = entries[i]
    if victim then
      cache[victim.key] = nil
    end
  end
end

local function remember_cache_entry(cache, key, value)
  local record = value or {}
  record.at = now_seconds()
  cache[key] = record
  prune_lru_cache(cache, max_mem_cache_entries())
  return record
end

local function resolve_tuning(root, defaults, opts)
  opts = opts or {}
  local bypass_cache = opts.bypass_cache and true or false
  if not root then
    return defaults
  end

  local tune_url = tuning_path(root)
  local tune_cha = fs.cha(tune_url)
  local cache_key = tostring(tune_url)
  if not tune_cha then
    M._tuning_cache[cache_key] = nil
    return defaults
  end

  if bypass_cache then
    M._tuning_cache[cache_key] = nil
  end

  local tune_mtime = tune_cha.mtime or 0
  local cached = M._tuning_cache[cache_key]
  if (not bypass_cache) and cached and cached.mtime == tune_mtime then
    cached.at = now_seconds()
    return {
      readability_zoom = cached.readability_zoom,
      page_tallness = defaults.page_tallness,
      profile = defaults.profile,
    }
  end

  local raw = run_capture("jq", {
    "-r",
    '.readabilityZoom // ""',
    cache_key,
  })
  if not raw then
    return defaults
  end

  local zoom_raw = raw:match("([^\r\n]*)")
  local parsed = {
    mtime = tune_mtime,
    readability_zoom = C.clamp_tuning(zoom_raw, defaults.readability_zoom),
    page_tallness = defaults.page_tallness,
    profile = defaults.profile,
  }
  remember_cache_entry(M._tuning_cache, cache_key, parsed)
  return {
    readability_zoom = parsed.readability_zoom,
    page_tallness = defaults.page_tallness,
    profile = defaults.profile,
  }
end

local function resolve_pane_profile(cols, rows, tuned_profile)
  local selected = normalize_profile(tuned_profile, default_render_profile())
  if selected ~= "auto" then
    return selected
  end

  if not auto_profile_enabled() then
    return "balanced"
  end

  local c = math.max(0, tonumber(cols) or 0)
  local r = math.max(0, tonumber(rows) or 0)
  local fast_cols = auto_fast_cols()
  local fast_rows = auto_fast_rows()
  local quality_cols = auto_quality_cols()
  local quality_rows = auto_quality_rows()

  if c > 0 and r > 0 then
    if c <= fast_cols or r <= fast_rows then
      return "fast"
    end
    if c >= quality_cols and r >= quality_rows then
      return "quality"
    end
  end

  if in_tmux_session() and (c <= (fast_cols + 12) or r <= (fast_rows + 4)) then
    return "fast"
  end

  return "balanced"
end

local function render_request_for_area(area, root, quick_mode, target_page, opts)
  local cols = math.max(0, tonumber(area and area.w) or 0)
  local rows = math.max(0, tonumber(area and area.h) or 0)
  local tune = resolve_tuning(root, {
    readability_zoom = readability_zoom(),
    page_tallness = page_tallness_scale(),
    profile = default_render_profile(),
  }, opts)
  local readability = C.clamp_tuning(tune.readability_zoom, readability_zoom())
  local page_tallness = C.clamp_tuning(tune.page_tallness, page_tallness_scale())
  local pane_profile = resolve_pane_profile(cols, rows, tune.profile)
  local effective_quick_mode = quick_mode and true or pane_profile == "fast"

  local baseline_scaled = 0
  local by_cols_scaled = 0
  local scaled_width = base_render_width_px()
  if cols > 0 then
    local cols_ratio = cols / base_preview_cols()
    if cols_ratio < 0.20 then
      cols_ratio = 0.20
    end
    baseline_scaled = math.floor((base_render_width_px() * math.sqrt(cols_ratio)) + 0.5)
    by_cols_scaled = math.floor((cols * render_px_per_col()) + 0.5)
    scaled_width = math.max(baseline_scaled, by_cols_scaled)
  end
  local scaled_after_cols = scaled_width
  scaled_width = math.floor((scaled_width / (readability ^ readability_width_weight())) + 0.5)
  local scaled_after_readability = scaled_width
  local terminal_program = terminal_program_name()
  local terminal_scale = render_width_terminal_scale()
  if math.abs(terminal_scale - 1.00) > 0.0001 then
    scaled_width = math.floor((scaled_width * terminal_scale) + 0.5)
  end
  local scaled_after_terminal = scaled_width
  local render_width = clamp(min_render_width_px(), scaled_width, max_render_width_px())
  local tmux_cap = 0
  if in_tmux_session() and cols > 0 then
    -- In split panes, wide-column estimates often overshoot visual pixels and make text too small.
    tmux_cap = math.max(min_render_width_px(), math.floor((cols * 8.0) + 0.5))
    render_width = math.min(render_width, tmux_cap)
  end
  local page_height = 0
  if dynamic_page_height_enabled() then
    local ratio_min = min_page_ratio()
    local ratio_max = max_page_ratio()
    local target_ratio = 1.45
    if cols > 0 and rows > 0 then
      local raw_ratio = (rows / cols) * terminal_cell_aspect_ratio()
      target_ratio = raw_ratio * page_height_bias()
      local pane_floor = raw_ratio * min_pane_fill_ratio()
      target_ratio = math.max(target_ratio, pane_floor)
    end
    target_ratio = math.max(ratio_min, math.min(ratio_max, target_ratio))
    target_ratio = target_ratio * page_tallness
    page_height = clamp(min_page_height_px(), math.floor((render_width * target_ratio) + 0.5), max_page_height_px())
  end

  return {
    render_width_px = render_width,
    page_height_px = page_height,
    preview_cols = cols,
    preview_rows = rows,
    quick_mode = effective_quick_mode,
    target_page = math.max(0, tonumber(target_page) or 0),
    readability_zoom = readability,
    page_tallness = page_tallness,
    render_profile = pane_profile,
    terminal_program = terminal_program,
    terminal_scale = terminal_scale,
    render_calc_baseline_px = math.max(0, baseline_scaled),
    render_calc_by_cols_px = math.max(0, by_cols_scaled),
    render_calc_after_cols_px = math.max(0, scaled_after_cols),
    render_calc_after_readability_px = math.max(0, scaled_after_readability),
    render_calc_after_terminal_px = math.max(0, scaled_after_terminal),
    render_calc_tmux_cap_px = math.max(0, tmux_cap),
  }
end

local function resolve_page_url(root, digest, skip)
  local page = math.max(0, tonumber(skip) or 0)
  for i = page, 0, -1 do
    local candidate = C.page_img_path(root, digest, i)
    if fs.cha(candidate) then
      return candidate, i
    end
  end
  return base_img_path(root, digest), 0
end

local function show_runtime_path_hint_once()
  if M._runtime_path_checked then
    return
  end
  M._runtime_path_checked = true

  if not in_tmux_session() then
    return
  end

  local allow_raw = run_capture("tmux", {
    "show",
    "-gv",
    "allow-passthrough",
  })
  local allow = tostring(allow_raw or ""):gsub("%s+$", "")
  if allow ~= "on" and allow ~= "all" then
    ya.notify({
      title = "Obsidian Preview",
      content = "tmux allow-passthrough is off. Image scaling may look wrong. Add: set -g allow-passthrough on",
      timeout = 2.5,
      level = "warn",
    })
  end

  local term = tostring(os.getenv("TERM") or "")
  if term ~= "" and term:sub(1, 4) ~= "tmux" and term:sub(1, 6) ~= "screen" then
    ya.notify({
      title = "Obsidian Preview",
      content = "TERM inside tmux looks unusual (" .. term .. "). Preview behavior may be unstable.",
      timeout = 2.2,
      level = "warn",
    })
  end
end

read_meta_info = function(root, digest)
  local meta_url = C.meta_path(root, digest)
  local meta_cha = fs.cha(meta_url)
  local cache_key = tostring(meta_url)
  if not meta_cha then
    M._meta_cache[cache_key] = nil
    return nil
  end

  local meta_mtime = meta_cha.mtime or 0
  local cached = M._meta_cache[cache_key]
  if cached and cached.mtime == meta_mtime then
    cached.at = now_seconds()
    return {
      page_count = cached.page_count,
      render_width_px = cached.render_width_px,
      page_height_px = cached.page_height_px,
      readability_zoom = cached.readability_zoom,
      page_tallness = cached.page_tallness,
      preview_cols = cached.preview_cols,
      preview_rows = cached.preview_rows,
      render_profile = cached.render_profile,
    }
  end

  local raw, err = run_capture("jq", {
    "-r",
    '[.pageCount // 0, .renderWidthPx // 0, .pageHeightPx // 0, .readabilityZoom // 0, .pageTallness // 0, .previewCols // 0, .previewRows // 0, .renderProfile // ""] | @tsv',
    tostring(meta_url),
  })
  if not raw then
    return nil, err
  end

  local page_count_raw, width_raw, page_height_raw, zoom_raw, tall_raw, cols_raw, rows_raw, profile_raw =
    raw:match("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\r\n]*)")
  local page_count = tonumber(page_count_raw or "")
  local width = tonumber(width_raw or "")
  local page_height = tonumber(page_height_raw or "")
  local zoom = tonumber(zoom_raw or "")
  local tall = tonumber(tall_raw or "")
  local cols = tonumber(cols_raw or "")
  local rows = tonumber(rows_raw or "")
  if not width or width <= 0 then
    M._meta_cache[cache_key] = nil
    return nil
  end
  local parsed = {
    page_count = (page_count and page_count > 0) and math.floor(page_count) or nil,
    render_width_px = math.floor(width),
    page_height_px = (page_height and page_height > 0) and math.floor(page_height) or nil,
    readability_zoom = (zoom and zoom > 0) and zoom or nil,
    page_tallness = (tall and tall > 0) and tall or nil,
    preview_cols = (cols and cols > 0) and math.floor(cols) or nil,
    preview_rows = (rows and rows > 0) and math.floor(rows) or nil,
    render_profile = normalize_profile(profile_raw, "auto"),
  }
  remember_cache_entry(M._meta_cache, cache_key, {
    mtime = meta_mtime,
    page_count = parsed.page_count,
    render_width_px = parsed.render_width_px,
    page_height_px = parsed.page_height_px,
    readability_zoom = parsed.readability_zoom,
    page_tallness = parsed.page_tallness,
    preview_cols = parsed.preview_cols,
    preview_rows = parsed.preview_rows,
    render_profile = parsed.render_profile,
  })
  return parsed
end

local function read_refresh_status(root, digest)
  local status_url = status_path(root, digest)
  local status_cha = fs.cha(status_url)
  local cache_key = tostring(status_url)
  if not status_cha then
    M._status_cache[cache_key] = nil
    return nil
  end

  local status_mtime = status_cha.mtime or 0
  local cached = M._status_cache[cache_key]
  if cached and cached.mtime == status_mtime then
    cached.at = now_seconds()
    return cached.value
  end

  local raw = run_capture("jq", {
    "-r",
    '[.state // "", .stage // "", (.quickMode // false), .renderProfile // "", .startedAt // "", .updatedAt // "", .requestId // "", (if .error | type == "object" then .error.message // "" elif .error | type == "string" then .error else "" end)] | @tsv',
    tostring(status_url),
  })
  if not raw then
    return nil
  end

  local state_raw, stage_raw, quick_raw, profile_raw, started_raw, updated_raw, request_id_raw, err_raw =
    raw:match("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\r\n]*)")

  local parsed = {
    state = state_raw or "",
    stage = stage_raw or "",
    quick_mode = is_true(quick_raw),
    render_profile = normalize_profile(profile_raw, "auto"),
    started_at = started_raw or "",
    updated_at = updated_raw or "",
    request_id = request_id_raw or "",
    error_message = err_raw or "",
  }

  remember_cache_entry(M._status_cache, cache_key, {
    mtime = status_mtime,
    value = parsed,
  })
  return parsed
end

local function refresh_stage_label(stage)
  local s = tostring(stage or ""):lower()
  if s == "" or s == "queued" then
    return "queued"
  elseif s == "prepare-host" then
    return "preparing"
  elseif s == "render-markdown" then
    return "rendering markdown"
  elseif s == "wait-stability" then
    return "waiting for layout"
  elseif s == "inline-images" then
    return "processing images"
  elseif s == "capture-canvas" then
    return "capturing image"
  elseif s == "capture-canvas-fallback" then
    return "capturing image (fallback)"
  elseif s == "write-pages" then
    return "writing pages"
  elseif s == "write-meta" then
    return "writing metadata"
  elseif s == "done" then
    return "done"
  end
  return s
end

local function refresh_stage_progress(stage, state)
  local s = tostring(stage or ""):lower()
  local st = tostring(state or ""):lower()
  if st == "done" or s == "done" then
    return 100
  end
  if st == "error" then
    return 100
  end
  if s == "" or s == "queued" then
    return 5
  elseif s == "prepare-host" then
    return 12
  elseif s == "render-markdown" then
    return 28
  elseif s == "wait-stability" then
    return 42
  elseif s == "inline-images" then
    return 58
  elseif s == "capture-canvas" or s == "capture-canvas-fallback" then
    return 74
  elseif s == "write-pages" then
    return 88
  elseif s == "write-meta" then
    return 96
  end
  return 35
end

local function refresh_spinner(elapsed)
  local frames = { "|", "/", "-", "\\" }
  local idx = (math.floor(math.max(0, tonumber(elapsed) or 0) * 3) % #frames) + 1
  return frames[idx]
end

local function refresh_progress_line(status, lock_request_id, elapsed, root)
  local stage = refresh_stage_label(status and status.stage or "")
  local suffix = ""
  local render_profile = normalize_profile(status and status.render_profile, "")
  if render_profile ~= "" and render_profile ~= "auto" then
    suffix = " [" .. render_profile .. "]"
  elseif status and status.quick_mode then
    suffix = " [fast]"
  end
  if stage == "queued" then
    local depth = request_queue_depth(root)
    if depth > 0 then
      suffix = suffix .. " [queue:" .. tostring(depth) .. "]"
    else
      suffix = suffix .. " [queue]"
    end
  end
  if lock_request_id ~= "" and status and status.request_id ~= "" and status.request_id ~= lock_request_id then
    suffix = suffix .. " [syncing request]"
  end

  local pct = refresh_stage_progress(status and status.stage or "", status and status.state or "")
  local spin = refresh_spinner(elapsed)
  return string.format("Regenerating preview: [%s] %d%% %s (%.1fs)%s", spin, pct, stage, elapsed, suffix)
end

local function resolve_rest_config()
  local env_key = env("OBSIDIAN_API_KEY", "")
  local host = env("OBSIDIAN_REST_HOST", "127.0.0.1")
  local insecure = is_true(env("OBSIDIAN_REST_INSECURE", "0"))
  local port = to_int(env("OBSIDIAN_REST_PORT", ""), nil)

  if not is_loopback_host(host) and not allow_remote_rest() then
    return nil, "remote REST host is blocked by default; set OBSIDIAN_REST_ALLOW_REMOTE=1 if intentional"
  end

  if (not insecure) and (not is_loopback_host(host)) and (not verify_tls_certs(host)) then
    return nil, "remote HTTPS requires TLS verification; set OBSIDIAN_REST_VERIFY_TLS=1"
  end

  local settings_path = C.vault_root() .. "/.obsidian/plugins/obsidian-local-rest-api/data.json"
  local raw, jq_err = run_capture("jq", {
    "-r",
    '[.apiKey // "", (.port // 27124), (.insecurePort // 27123), (.enableInsecureServer // false)] | @tsv',
    settings_path,
  })

  if not raw then
    if env_key ~= "" and port and prefer_env_api_key() then
      return {
        key = env_key,
        host = host,
        port = port,
        insecure = insecure,
      }, nil
    end
    return nil, "failed to read local-rest-api settings: " .. tostring(jq_err)
  end

  local file_key, secure_port, insecure_port, file_insecure = raw:match("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\r\n]*)")
  file_key = tostring(file_key or "")

  local insecure_env = env("OBSIDIAN_REST_INSECURE", "")
  local final_insecure = insecure
  if insecure_env == "" then
    if is_loopback_host(host) then
      final_insecure = is_true(file_insecure)
    else
      final_insecure = false
    end
  end

  local final_key = file_key
  if final_key == "" and prefer_env_api_key() then
    final_key = env_key
  end
  if env_key ~= "" and prefer_env_api_key() then
    final_key = env_key
  end
  if final_key == "" then
    return nil, "apiKey missing in local-rest-api settings"
  end

  if final_insecure and (not is_loopback_host(host)) then
    return nil, "remote insecure REST is blocked; use HTTPS (OBSIDIAN_REST_INSECURE=0)"
  end

  return {
    key = final_key,
    host = host,
    port = port or to_int(final_insecure and insecure_port or secure_port, final_insecure and 27123 or 27124),
    insecure = final_insecure,
  }, nil
end

local function read_rest_key_from_settings_path(path)
  if not path or path == "" then
    return nil
  end

  local raw = run_capture("jq", {
    "-r",
    '.apiKey // ""',
    tostring(path),
  })
  if not raw then
    return nil
  end

  local key = (raw:match("([^\r\n]*)") or ""):gsub("%s+$", "")
  if key == "" then
    return nil
  end
  return key
end

local function rest_endpoint_cache_key(host, port, insecure)
  return tostring(insecure and "http" or "https") .. "://" .. tostring(host or "") .. ":" .. tostring(port or "")
end

local function remember_rest_auth(host, port, insecure, key)
  local safe_key = tostring(key or "")
  if safe_key == "" then
    return
  end
  M._rest_auth_cache[rest_endpoint_cache_key(host, port, insecure)] = safe_key
end

local function cached_rest_auth(host, port, insecure)
  local key = M._rest_auth_cache[rest_endpoint_cache_key(host, port, insecure)]
  if key and key ~= "" then
    return key
  end
  return nil
end

local function clear_cached_rest_auth(host, port, insecure)
  M._rest_auth_cache[rest_endpoint_cache_key(host, port, insecure)] = nil
end

local function parent_dir(path)
  local p = tostring(path or ""):gsub("/+$", "")
  return p:match("^(.*)/[^/]+$") or ""
end

local function scan_settings_paths_under_root(root, push_path)
  local root_path = tostring(root or "")
  if root_path == "" then
    return
  end

  local cha = fs.cha(Url(root_path))
  if not cha or not cha.is_dir then
    return
  end

  local out = run_capture("find", {
    root_path,
    "-maxdepth", "12",
    "-type", "f",
    "-path", "*/.obsidian/plugins/obsidian-local-rest-api/data.json",
    "-print",
  })
  if not out then
    return
  end

  for line in tostring(out):gmatch("[^\r\n]+") do
    push_path(line)
  end
end

local function scan_extra_rest_settings_paths(force_refresh)
  if not allow_home_key_scan() then
    return {}
  end

  local now = os.time()
  local cached = M._rest_settings_scan_cache
  if (not force_refresh) and cached and (now - tonumber(cached.at or 0)) < 300 and type(cached.paths) == "table" then
    return cached.paths
  end

  local paths = {}
  local seen = {}
  local function push_path(path)
    local p = tostring(path or "")
    if p == "" or seen[p] then
      return
    end
    seen[p] = true
    table.insert(paths, p)
  end

  local home = tostring(os.getenv("HOME") or "")
  if home ~= "" then
    local scan_roots = {
      home .. "/obsidian",
      home .. "/Documents",
      home .. "/Desktop",
      home .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents",
    }
    local vault_parent = parent_dir(C.vault_root())
    if vault_parent ~= "" then
      table.insert(scan_roots, vault_parent)
    end
    for _, root in ipairs(scan_roots) do
      scan_settings_paths_under_root(root, push_path)
    end

    if #paths == 0 then
      -- Last-resort global scan (rare): helps when vaults live outside common roots.
      local out = run_capture("find", {
        home,
        "-maxdepth", "12",
        "-type", "f",
        "-path", "*/.obsidian/plugins/obsidian-local-rest-api/data.json",
        "-print",
      })
      if out then
        for line in tostring(out):gmatch("[^\r\n]+") do
          push_path(line)
        end
      end
    end
  end

  M._rest_settings_scan_cache = {
    at = now,
    paths = paths,
  }
  return paths
end

local function collect_alternate_rest_keys(exclude_key, opts)
  opts = opts or {}
  local keys = {}
  local seen = {}

  local function push_key(key)
    if not key or key == "" then
      return
    end
    if key == tostring(exclude_key or "") then
      return
    end
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(keys, key)
  end

  push_key(read_rest_key_from_settings_path(C.vault_root() .. "/.obsidian/plugins/obsidian-local-rest-api/data.json"))
  push_key(env("OBSIDIAN_API_KEY", ""))

  if not allow_home_key_scan() then
    return keys
  end

  local home = tostring(os.getenv("HOME") or "")
  if home ~= "" then
    push_key(read_rest_key_from_settings_path(home .. "/obsidian/.obsidian/plugins/obsidian-local-rest-api/data.json"))
  end

  for _, settings_path in ipairs(scan_extra_rest_settings_paths(opts.force_scan and true or false)) do
    push_key(read_rest_key_from_settings_path(settings_path))
  end

  return keys
end

local function build_post_args(url, cfg, auth_mode)
  local args = {
    "-sS",
    "--connect-timeout", tostring(rest_connect_timeout_secs()),
    "--max-time", tostring(rest_max_time_secs()),
    "-X", "POST",
    "-o", "/dev/null",
    "-w", "%{http_code}",
  }
  if auth_mode == "stdin" then
    args[#args + 1] = "-H"
    args[#args + 1] = "@-"
  else
    args[#args + 1] = "-H"
    args[#args + 1] = "Authorization: Bearer " .. tostring(cfg.key or "")
  end
  if (not cfg.insecure) and (not verify_tls_certs(cfg.host)) then
    if not is_loopback_host(cfg.host) then
      return nil, "TLS verification disabled for remote host is not allowed"
    end
    table.insert(args, 1, "-k")
  end
  args[#args + 1] = url
  return args, nil
end

local function http_post(url, cfg)
  cleanup_stale_auth_headers(C.cache_root())

  -- Try stdin header first.
  local args, tls_err = build_post_args(url, cfg, "stdin")
  if not args then
    return nil, tls_err
  end
  local auth_header = "Authorization: Bearer " .. cfg.key .. "\n"
  local status, err = C.run_capture_with_stdin("curl", args, auth_header)
  if status then
    local code = status:gsub("%s+$", "")
    if code:match("^2%d%d$") then
      return true, nil
    end
  end

  -- Fallback for environments where stdin header piping to curl is unreliable.
  local fb_args, fb_tls_err = build_post_args(url, cfg, "direct")
  if not fb_args then
    return nil, fb_tls_err
  end
  local status_fb, err_fb = run_capture("curl", fb_args)
  if not status_fb then
    return nil, err_fb or err
  end
  local code_fb = status_fb:gsub("%s+$", "")
  if code_fb:match("^2%d%d$") then
    return true, nil
  end

  return nil, "http status " .. tostring(code_fb)
end

local function request_render_by_rest(_rel)
  local cfg, cfg_err = resolve_rest_config()
  if not cfg then
    return nil, cfg_err
  end

  if cfg.insecure and (not is_loopback_host(cfg.host)) then
    return nil, "insecure remote REST is blocked; use HTTPS"
  end

  local cached_key = cached_rest_auth(cfg.host, cfg.port, cfg.insecure)
  if cached_key and cached_key ~= cfg.key then
    cfg.key = cached_key
  end

  local scheme = cfg.insecure and "http" or "https"
  local base = string.format("%s://%s:%d", scheme, cfg.host, cfg.port)
  local cmd_url = string.format("%s/commands/%s", base, url_encode(command_id()))

  local ok_cmd, err_cmd = http_post(cmd_url, cfg)
  if not ok_cmd then
    local err_text = tostring(err_cmd or "")
    if err_text:find("http status 401", 1, true) then
      clear_cached_rest_auth(cfg.host, cfg.port, cfg.insecure)
      if not is_loopback_host(cfg.host) then
        return nil, "command failed: http status 401 (alternate key retry is disabled for non-loopback hosts)"
      end
      local alt_keys = collect_alternate_rest_keys(cfg.key, { force_scan = true })
      for _, alt_key in ipairs(alt_keys) do
        local retry_ok = http_post(cmd_url, {
          key = alt_key,
          host = cfg.host,
          port = cfg.port,
          insecure = cfg.insecure,
        })
        if retry_ok then
          remember_rest_auth(cfg.host, cfg.port, cfg.insecure, alt_key)
          return true, nil
        end
      end
      return nil,
        "command failed: http status 401 (API key mismatch; set OBSIDIAN_API_KEY or opt in with OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN=1)"
    end
    return nil, "command failed: " .. err_text
  end

  remember_rest_auth(cfg.host, cfg.port, cfg.insecure, cfg.key)
  return true, nil
end

local function request_render_by_cli()
  local errors = {}
  local cmd = command_id()
  local selected_vault = vault_name()

  for _, bin in ipairs(cli_bin_candidates()) do
    local args = {}
    if selected_vault ~= "" then
      -- Obsidian CLI expects `vault=<name>` before subcommands.
      table.insert(args, "vault=" .. selected_vault)
    end
    table.insert(args, "command")
    table.insert(args, "id=" .. cmd)

    local runner = Command(bin)
    for _, arg in ipairs(args) do
      runner:arg(arg)
    end

    local child, spawn_err = runner:stdout(Command.PIPED):stderr(Command.PIPED):spawn()
    if not child then
      table.insert(errors, bin .. ": " .. tostring(spawn_err or "spawn failed"):gsub("%s+$", ""))
    else
      local output, wait_err = child:wait_with_output()
      if not output then
        table.insert(errors, bin .. ": " .. tostring(wait_err or "wait failed"):gsub("%s+$", ""))
      elseif output.status.success then
        return true, nil
      else
        local err_text = output.stderr ~= "" and output.stderr or output.stdout
        if err_text == "" then
          err_text = "exit code " .. tostring(output.status.code)
        end
        table.insert(errors, bin .. ": " .. err_text:gsub("%s+$", ""))
      end
    end
  end

  return nil, "failed to execute Obsidian CLI: " .. table.concat(errors, " | ")
end

local function request_render_by_uri(_rel)
  local uri = string.format(
    "%s?vault=%s&commandid=%s",
    uri_scheme(),
    url_encode(vault_name()),
    url_encode(command_id())
  )

  local function try_open(cmd, args)
    local runner = Command(cmd)
    for _, arg in ipairs(args) do
      runner:arg(arg)
    end
    local child, spawn_err = runner:stdout(Command.PIPED):stderr(Command.PIPED):spawn()
    if not child then
      return nil, spawn_err
    end
    local output, wait_err = child:wait_with_output()
    if not output then
      return nil, wait_err
    end
    if not output.status.success then
      local err_text = output.stderr ~= "" and output.stderr or ("exit code " .. tostring(output.status.code))
      return nil, err_text
    end
    return true, nil
  end

  local attempts = {}
  local open_args = {}
  if open_background() then
    table.insert(open_args, "-g")
  end
  table.insert(open_args, uri)
  table.insert(attempts, { name = "open", cmd = "open", args = open_args })
  table.insert(attempts, { name = "xdg-open", cmd = "xdg-open", args = { uri } })
  table.insert(attempts, { name = "cmd.exe", cmd = "cmd.exe", args = { "/c", "start", "", uri } })

  local escaped_uri = uri:gsub("'", "''")
  table.insert(attempts, {
    name = "powershell",
    cmd = "powershell.exe",
    args = { "-NoProfile", "-Command", "Start-Process '" .. escaped_uri .. "'" },
  })

  local errors = {}
  for _, attempt in ipairs(attempts) do
    local ok_open, err_open = try_open(attempt.cmd, attempt.args)
    if ok_open then
      return true, nil
    end
    if err_open and err_open ~= "" then
      table.insert(errors, attempt.name .. ": " .. tostring(err_open):gsub("%s+$", ""))
    end
  end

  return nil, "failed to launch URI via open/xdg-open/cmd/powershell: " .. table.concat(errors, " | ")
end

local function show_markdown(job, opts)
  opts = opts or {}
  M._last_image_key = nil
  local err, bound = ya.preview_code(job)
  if bound and (not opts.suppress_bound_emit) then
    ya.emit("peek", { bound, only_if = job.file.url, upper_bound = true })
  elseif err and not err:find("cancelled", 1, true) then
    require("empty").msg(job, err)
  end
end

local function show_refresh_overlay(job, line)
  local message = tostring(line or ""):gsub("%s+$", "")
  if message == "" then
    message = "Regenerating preview..."
  end
  require("empty").msg(job, message)
end

local function layout_wait_line(stable_for)
  return string.format(
    "Waiting for pane to settle... %.1fs / %.1fs",
    math.max(0.0, tonumber(stable_for) or 0.0),
    layout_settle_secs()
  )
end

local function area_signature(area)
  if not area then
    return "0:0"
  end

  return table.concat({
    tostring(area.w or 0),
    tostring(area.h or 0),
  }, ":")
end

local function layout_signature(area, render_req)
  local cols = math.max(0, tonumber(render_req and render_req.preview_cols) or 0)
  local rows = math.max(0, tonumber(render_req and render_req.preview_rows) or 0)
  local width_px = math.max(0, tonumber(render_req and render_req.render_width_px) or 0)
  local page_height_px = math.max(0, tonumber(render_req and render_req.page_height_px) or 0)
  local profile = normalize_profile(render_req and render_req.render_profile, "auto")
  return table.concat({
    area_signature(area),
    tostring(cols),
    tostring(rows),
    tostring(width_px),
    tostring(page_height_px),
    tostring(profile),
  }, "|")
end

local function image_signature(job, page_url)
  local cha = fs.cha(page_url)
  return table.concat({
    tostring(job.file.url),
    tostring(page_url),
    tostring((cha and cha.mtime) or 0),
    area_signature(job.area),
  }, "|")
end

local function digest_from_image_url(page_url)
  local path = tostring(page_url or "")
  path = path:gsub("\\", "/")
  local digest = path:match("/img/([A-Za-z0-9_-]+)%-%-p%d+%.png$")
  if digest and digest ~= "" then
    return digest
  end
  digest = path:match("/img/([A-Za-z0-9_-]+)%.png$")
  if digest and digest ~= "" then
    return digest
  end
  return ""
end

local function record_image_show_error(page_url, err)
  if not err then
    return
  end
  local digest = digest_from_image_url(page_url)
  local root = C.cache_root()
  local name = (digest ~= "") and (digest .. ".ui.error.txt") or "image-show.ui.error.txt"
  local log_path = root .. "/log/" .. name
  local payload = string.format(
    "%s\timage_show\t%s\t%s\n",
    os.date("!%Y-%m-%dT%H:%M:%SZ"),
    tostring(page_url or ""),
    short_text(tostring(err or "unknown error"), 220)
  )
  C.atomic_write_file(log_path, payload)
end

local function is_refresh_in_progress(root, digest, lock_url, img_cha, status)
  local lock_cha = fs.cha(lock_url)
  local lock_mtime = 0
  if lock_cha then
    lock_mtime = lock_cha.mtime or 0
    local lock_age = os.time() - lock_mtime
    local img_newer = img_cha and (img_cha.mtime or 0) >= lock_mtime
    local err_cha = fs.cha(Url(root .. "/log/" .. digest .. ".error.json"))
    local err_newer = err_cha and (err_cha.mtime or 0) >= lock_mtime

    if lock_mtime > 0 and lock_age <= lock_seconds() and (not img_newer) and (not err_newer) then
      return true
    end

    -- Stale/invalid lock: clear it and continue with status-based fallback.
    safe_remove_file(lock_url)
  end

  local status_state = tostring(status and status.state or ""):lower()
  if status_state ~= "running" then
    return false
  end

  local status_cha = fs.cha(status_path(root, digest))
  local status_mtime = (status_cha and status_cha.mtime) or 0
  if status_mtime <= 0 then
    return false
  end
  if (os.time() - status_mtime) > lock_seconds() then
    return false
  end
  if img_cha and (img_cha.mtime or 0) >= status_mtime then
    return false
  end

  return true
end

local function refresh_state_key(file_url, digest)
  return tostring(file_url) .. "|" .. tostring(digest)
end

local function layout_is_settled(file_url, digest, area, render_req)
  local key = refresh_state_key(file_url, digest)
  local sig = layout_signature(area, render_req)
  local now_tick = now_seconds()
  local cached = M._layout_stability[key]
  if not cached or cached.sig ~= sig then
    M._layout_stability[key] = {
      sig = sig,
      changed_at = now_tick,
      at = now_tick,
    }
    prune_lru_cache(M._layout_stability, max_mem_cache_entries())
    return false, 0.0, true
  end

  cached.at = now_tick
  local stable_for = math.max(0.0, now_tick - (tonumber(cached.changed_at or now_tick) or now_tick))
  local settled = stable_for >= layout_settle_secs()
  return settled, stable_for, false
end

local function mark_manual_refresh_pending(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  M._manual_refresh_pending[key] = now_seconds()
end

local function clear_manual_refresh_pending(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  M._manual_refresh_pending[key] = nil
end

local function is_manual_refresh_pending(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  return M._manual_refresh_pending[key] ~= nil
end

local function refresh_had_error(root, digest, lock_mtime)
  local err_cha = fs.cha(Url(root .. "/log/" .. digest .. ".error.json"))
  if not err_cha then
    return false
  end
  return (err_cha.mtime or 0) >= (lock_mtime or 0)
end

local function read_lock_request_id(lock_url)
  local lock_cha = fs.cha(lock_url)
  if not lock_cha then
    return ""
  end

  local raw = run_capture("jq", {
    "-r",
    '.requestId // ""',
    tostring(lock_url),
  })
  if not raw then
    return ""
  end

  local request_id = (raw:match("([^\r\n]*)") or ""):gsub("%s+$", "")
  if request_id:match("^[A-Za-z0-9._:-]{1,128}$") then
    return request_id
  end
  return ""
end

local function notify_refresh_started(opts)
  opts = opts or {}
  if not show_refresh_notify() then
    return
  end
  local suffix = ""
  if opts.queue_depth and tonumber(opts.queue_depth) and tonumber(opts.queue_depth) > 0 then
    suffix = " [queue:" .. tostring(math.max(1, math.floor(tonumber(opts.queue_depth) or 1))) .. "]"
  elseif opts.queued then
    suffix = " [queue]"
  end
  ya.notify({
    title = "Obsidian Preview",
    content = string.format("Regenerating preview: [%s] %d%% %s (%.1fs)%s", "/", 5, "queued", 0.0, suffix),
    timeout = math.max(2.2, progress_notify_interval_secs() + 1.0),
    level = "info",
  })
end

local function track_refresh_state(job, ctx, lock_url, img_cha, _stale)
  local key = refresh_state_key(job.file.url, ctx.digest)
  local state = M._refresh_state[key] or {
    active = false,
    preflight = false,
    lock_mtime = 0,
    next_poll_at = 0,
    started_at = 0,
    pending_skip = 0,
    stage_key = "",
    last_stage = "",
  }

  local status = read_refresh_status(ctx.root, ctx.digest)
  local refreshing = is_refresh_in_progress(ctx.root, ctx.digest, lock_url, img_cha, status)
  local lock_cha = fs.cha(lock_url)
  local lock_mtime = (lock_cha and lock_cha.mtime) or 0
  local lock_request_id = read_lock_request_id(lock_url)

  if refreshing then
    state.manual = state.manual or is_manual_refresh_pending(job.file.url, ctx.digest)
    local stage = refresh_stage_label(status and status.stage or "")
    local stage_key = string.format(
      "%s|%s|%s|%s",
      tostring(status and status.state or ""),
      tostring(status and status.stage or ""),
      tostring(status and status.request_id or ""),
      tostring(lock_request_id or "")
    )
    local now_tick = now_seconds()
    local started_at = (state.started_at and state.started_at > 0)
      and state.started_at
      or ((lock_mtime > 0) and lock_mtime or now_tick)
    local elapsed = math.max(0, now_tick - started_at)
    local periodic_progress = show_refresh_notify()
      and state.active
      and ((now_tick - (tonumber(state.last_notify_at or 0) or 0)) >= progress_notify_interval_secs())

    local progress_notify_enabled = show_refresh_notify() or state.manual
    local should_notify_progress = progress_notify_enabled and (
      (not state.active)
      or ((state.lock_mtime or 0) ~= lock_mtime)
      or (state.stage_key ~= stage_key)
      or periodic_progress
    )
    local progress_line = refresh_progress_line(status, lock_request_id, elapsed, ctx.root)
    state.progress_line = progress_line
    if should_notify_progress then
      ya.notify({
        title = "Obsidian Preview",
        content = progress_line,
        timeout = math.max(2.2, progress_notify_interval_secs() + 1.0),
        level = "info",
      })
      state.last_notify_at = now_tick
    end

    state.active = true
    state.preflight = false
    state.lock_mtime = lock_mtime
    state.started_at = started_at
    state.pending_skip = math.max(0, tonumber(job.skip) or 0)
    state.stage_key = stage_key
    state.last_stage = stage
    state.request_id = lock_request_id ~= "" and lock_request_id or (status and status.request_id or "")
    state.last_error = status and status.error_message or ""
    remember_cache_entry(M._refresh_state, key, state)
    return true, state
  end

  if state.active then
    if state.preflight then
      local now_tick = now_seconds()
      local started_at = state.started_at or now_tick
      local elapsed = math.max(0, now_tick - started_at)
      local grace = math.max(3.0, refresh_md_poll_secs() * 6)
      if elapsed < grace then
        state.progress_line = string.format("Regenerating preview: [%s] %d%% %s (%.1fs)", refresh_spinner(elapsed), 5, "queued", elapsed)
        remember_cache_entry(M._refresh_state, key, state)
        return true, state
      end

      if show_refresh_notify() then
        ya.notify({
          title = "Obsidian Preview",
          content = "Regeneration did not start yet. Retrying...",
          timeout = 1.8,
          level = "warn",
        })
      end
      M._refresh_state[key] = nil
      return false, nil
    end

    local manual = state.manual or is_manual_refresh_pending(job.file.url, ctx.digest)
    local status_failed = status and tostring(status.state or ""):lower() == "error"
    local file_failed = (state.lock_mtime and state.lock_mtime > 0)
      and refresh_had_error(ctx.root, ctx.digest, state.lock_mtime)
      or false
    local failed = status_failed or file_failed
    local started_at = state.started_at or state.lock_mtime or now_seconds()
    local elapsed = math.max(0, now_seconds() - started_at)

    if show_refresh_notify() then
      if failed then
        local err_message = short_text((status and status.error_message) or state.last_error or "unknown error", 90)
        ya.notify({
          title = "Obsidian Preview",
          content = "Regeneration failed (" .. err_message .. "). Keeping previous preview.",
          timeout = 2.3,
          level = "warn",
        })
      else
        ya.notify({
          title = "Obsidian Preview",
          content = string.format("Preview updated in %.1fs.", elapsed),
          timeout = 1.4,
          level = "info",
        })
      end
    end

    if manual then
      if failed then
        local err_message = short_text((status and status.error_message) or state.last_error or "unknown error", 90)
        ya.notify({
          title = "Obsidian Preview",
          content = "Regeneration failed (" .. err_message .. ").",
          timeout = 2.5,
          level = "warn",
        })
      else
        ya.notify({
          title = "Obsidian Preview",
          content = string.format("Regenerated preview in %.1fs.", elapsed),
          timeout = 1.6,
          level = "info",
        })
      end
    end

    M._refresh_state[key] = nil
    clear_manual_refresh_pending(job.file.url, ctx.digest)
    M._last_image_key = nil
    ya.emit("peek", { math.max(0, tonumber(state.pending_skip) or 0), only_if = job.file.url })
    return false, nil
  end

  M._refresh_state[key] = nil
  return false, nil
end

local function maybe_poll_refresh(job, state, opts)
  if not state or not state.active then
    return
  end

  opts = opts or {}
  local poll_interval = refresh_poll_secs()
  if opts.markdown_fallback then
    poll_interval = refresh_md_poll_secs()
  end

  local now = now_seconds()
  if now < (state.next_poll_at or 0) then
    return
  end

  state.next_poll_at = now + poll_interval
  ya.emit("peek", { math.max(0, tonumber(job.skip) or 0), only_if = job.file.url })
end

local function maybe_poll_layout_settle(job, file_url, digest, opts)
  opts = opts or {}
  local key = refresh_state_key(file_url, digest)
  local state = M._layout_stability[key]
  if not state then
    return
  end

  local interval = refresh_poll_secs()
  if opts.markdown_fallback then
    interval = refresh_md_poll_secs()
  end
  local now_tick = now_seconds()
  local next_poll_at = tonumber(state.next_poll_at or 0) or 0
  if now_tick < next_poll_at then
    return
  end
  state.next_poll_at = now_tick + interval
  state.at = now_tick
  ya.emit("peek", { math.max(0, tonumber(job.skip) or 0), only_if = job.file.url })
end

local function show_image(job, page_url)
  local key = image_signature(job, page_url)
  if M._last_image_key ~= key then
    local _, err = ya.image_show(page_url, job.area)
    if err then
      -- Keep retrying when the image backend reports errors.
      M._last_image_key = nil
      record_image_show_error(page_url, err)
    else
      M._last_image_key = key
    end
    return ya.preview_widget(job, err)
  end
  return
end

local function pane_layout_changed(meta, render_req)
  if not auto_fit_enabled() or not meta or not render_req then
    return false
  end

  local target_cols = math.max(0, tonumber(render_req.preview_cols) or 0)
  local target_rows = math.max(0, tonumber(render_req.preview_rows) or 0)
  local existing_cols = math.max(0, tonumber(meta.preview_cols) or 0)
  local existing_rows = math.max(0, tonumber(meta.preview_rows) or 0)

  if target_cols > 0 and existing_cols > 0 and math.abs(existing_cols - target_cols) > pane_cols_tolerance() then
    return true
  end
  if target_rows > 0 and existing_rows > 0 and math.abs(existing_rows - target_rows) > pane_rows_tolerance() then
    return true
  end

  return false
end

local function adapt_render_request_with_meta(meta, render_req)
  if not auto_fit_enabled() or not meta or not render_req then
    return render_req
  end

  local prev_cols = math.max(0, tonumber(meta.preview_cols) or 0)
  local prev_rows = math.max(0, tonumber(meta.preview_rows) or 0)
  local next_cols = math.max(0, tonumber(render_req.preview_cols) or 0)
  local next_rows = math.max(0, tonumber(render_req.preview_rows) or 0)
  local prev_width = math.max(0, tonumber(meta.render_width_px) or 0)
  local prev_page = math.max(0, tonumber(meta.page_height_px) or 0)

  if prev_cols > 0 and next_cols > 0 and prev_width > 0 then
    local new_width = tonumber(render_req.render_width_px) or 0
    local projected_width = math.floor((prev_width * (next_cols / prev_cols)) + 0.5)
    -- Skip blending when the difference is large (e.g. default params changed).
    -- Blending in that case anchors toward stale values and delays convergence.
    local width_diff_ratio = (new_width > 0 and projected_width > 0)
      and math.abs(new_width - projected_width) / math.max(new_width, projected_width)
      or 0
    if width_diff_ratio < 0.15 then
      local blended_width = math.floor((new_width * 0.58) + (projected_width * 0.42) + 0.5)
      render_req.render_width_px = clamp(min_render_width_px(), blended_width, max_render_width_px())
    end
    -- else: keep render_req.render_width_px as-is (no blending)
  end

  if (tonumber(render_req.page_height_px) or 0) > 0 and prev_rows > 0 and next_rows > 0 and prev_page > 0 then
    local new_page = tonumber(render_req.page_height_px) or 0
    local projected_page = math.floor((prev_page * (next_rows / prev_rows)) + 0.5)
    local page_diff_ratio = (new_page > 0 and projected_page > 0)
      and math.abs(new_page - projected_page) / math.max(new_page, projected_page)
      or 0
    if page_diff_ratio < 0.15 then
      local blended_page = math.floor((new_page * 0.60) + (projected_page * 0.40) + 0.5)
      render_req.page_height_px = clamp(min_page_height_px(), blended_page, max_page_height_px())
    end
    -- else: keep render_req.page_height_px as-is (no blending)
  end

  return render_req
end

local function page_missing_for_request(root, digest, render_req, meta)
  if not render_req then
    return false
  end

  local target_page = math.max(0, tonumber(render_req.target_page) or 0)
  if target_page <= 0 then
    return false
  end

  local total_pages = math.max(0, tonumber(meta and meta.page_count) or 0)
  if total_pages > 0 and target_page >= total_pages then
    return false
  end

  return fs.cha(C.page_img_path(root, digest, target_page)) == nil
end

local function is_stale(img_cha, note_mtime, root, digest, render_req)
  if not img_cha then
    return true
  end

  local img_mtime = img_cha.mtime or 0
  if img_mtime <= 0 then
    return true
  end

  if os.time() - img_mtime > ttl_seconds() then
    return true
  end

  if note_mtime and note_mtime > img_mtime then
    return true
  end

  local renderer_cha = fs.cha(Url(renderer_main_js()))
  if renderer_cha and (renderer_cha.mtime or 0) > img_mtime then
    return true
  end

  if render_req and (tonumber(render_req.render_width_px) or 0) > 0 then
    local meta = read_meta_info(root, digest)
    if not meta then
      return true
    end

    local target_page = math.max(0, tonumber(render_req.target_page) or 0)
    if target_page > 0 then
      local total_pages = math.max(0, tonumber(meta.page_count) or 0)
      if total_pages <= 0 then
        return true
      end
      if target_page < total_pages and not fs.cha(C.page_img_path(root, digest, target_page)) then
        return true
      end
    end

    local target_width = math.max(1, tonumber(render_req.render_width_px) or 1)
    local tolerance = math.max(render_width_tolerance_px(), math.floor(target_width * 0.03))
    if math.abs((meta.render_width_px or 0) - target_width) > tolerance then
      return true
    end

    if (tonumber(render_req.page_height_px) or 0) > 0 then
      local target_page_height = math.max(1, tonumber(render_req.page_height_px) or 1)
      local existing_page_height = tonumber(meta.page_height_px or 0)
      if existing_page_height <= 0 then
        return true
      end
      local page_tol = math.max(page_height_tolerance_px(), math.floor(target_page_height * 0.04))
      if math.abs(existing_page_height - target_page_height) > page_tol then
        return true
      end
    end

    local target_zoom = tonumber(render_req.readability_zoom or 0)
    if target_zoom > 0 then
      local existing_zoom = tonumber(meta.readability_zoom or 0)
      if existing_zoom <= 0 then
        return true
      end
      if math.abs(existing_zoom - target_zoom) > 0.015 then
        return true
      end
    end

    local target_tall = tonumber(render_req.page_tallness or 0)
    if target_tall > 0 then
      local existing_tall = tonumber(meta.page_tallness or 0)
      if existing_tall <= 0 then
        return true
      end
      if math.abs(existing_tall - target_tall) > 0.015 then
        return true
      end
    end

    local target_profile = normalize_profile(render_req.render_profile, "")
    if target_profile ~= "" then
      local existing_profile = normalize_profile(meta.render_profile, "")
      if existing_profile == "" then
        return true
      end
      if existing_profile ~= target_profile then
        return true
      end
    end
  end

  return false
end

local function can_request_render_now(root, digest, lock_url, img_cha)
  local lock_cha = fs.cha(lock_url)
  if not lock_cha then
    return true
  end

  local lock_mtime = lock_cha.mtime or 0
  local lock_age = os.time() - lock_mtime
  if img_cha and (img_cha.mtime or 0) >= lock_mtime then
    safe_remove_file(lock_url)
    return true
  end

  local err_cha = fs.cha(Url(root .. "/log/" .. digest .. ".error.json"))
  if err_cha and (err_cha.mtime or 0) >= lock_mtime then
    safe_remove_file(lock_url)
    return true
  end

  local status_cha = fs.cha(status_path(root, digest))
  if (not img_cha) and (not status_cha) and lock_age > math.min(lock_quick_retry_secs(), lock_seconds()) then
    -- Command likely did not reach exporter; retry sooner than full lock timeout.
    safe_remove_file(lock_url)
    return true
  end

  if lock_age > lock_seconds() then
    safe_remove_file(lock_url)
    return true
  end
  return false
end

local _fallback_base_hints = {
  "failed to connect",
  "couldn't connect",
  "connection refused",
  "timed out",
  "no route to host",
  "api key missing",
  "local-rest-api settings",
  "http status 000",
}

local function error_matches_fallback_hints(rest_err, extra_hints)
  local text = tostring(rest_err or ""):lower()
  if text == "" then
    return false
  end
  for _, hint in ipairs(_fallback_base_hints) do
    if text:find(hint, 1, true) then
      return true
    end
  end
  if extra_hints then
    for _, hint in ipairs(extra_hints) do
      if text:find(hint, 1, true) then
        return true
      end
    end
  end
  return false
end

local function should_auto_uri_fallback(rest_err)
  return error_matches_fallback_hints(rest_err)
end

local function should_auto_cli_fallback(rest_err)
  return error_matches_fallback_hints(rest_err, { "http status 401" })
end

local function maybe_notify_fallback(target)
  if not verbose_refresh_notify() then
    return
  end
  local now = now_seconds()
  local last = tonumber(M._rest_fallback_notice_at or 0) or 0
  if (now - last) < 4.0 then
    return
  end
  M._rest_fallback_notice_at = now
  ya.notify({
    title = "Obsidian Preview",
    content = "REST is unavailable. Trying " .. tostring(target or "fallback") .. " in background...",
    timeout = 1.8,
    level = "info",
  })
end

local function request_render(rel, digest, lock_url, root, render_req)
  local req_id = new_request_id(rel)
  local queue_url = request_queue_path(root, digest)
  local req_file = tostring(request_path(root))
  local ok_txt, err_txt = C.atomic_write_file(req_file, rel .. "\n")
  if not ok_txt then
    return nil, "failed to write request file: " .. tostring(err_txt)
  end
  C.chmod_600(req_file)

  local payload = string.format(
    '{"path":%s,"digest":%s,"requestId":%s,"renderWidthPx":%d,"pageHeightPx":%d,"previewCols":%d,"previewRows":%d,"targetPage":%d,"quickMode":%s,"renderProfile":%s,"terminalProgram":%s,"terminalScale":%.4f,"renderCalcBaselinePx":%d,"renderCalcByColsPx":%d,"renderCalcAfterColsPx":%d,"renderCalcAfterReadabilityPx":%d,"renderCalcAfterTerminalPx":%d,"renderCalcTmuxCapPx":%d,"readabilityZoom":%.4f,"pageTallness":%.4f,"requestedAt":%d}\n',
    json_string(rel),
    json_string(digest),
    json_string(req_id),
    math.max(0, tonumber(render_req and render_req.render_width_px) or 0),
    math.max(0, tonumber(render_req and render_req.page_height_px) or 0),
    math.max(0, tonumber(render_req and render_req.preview_cols) or 0),
    math.max(0, tonumber(render_req and render_req.preview_rows) or 0),
    math.max(0, tonumber(render_req and render_req.target_page) or 0),
    (render_req and render_req.quick_mode) and "true" or "false",
    json_string(normalize_profile(render_req and render_req.render_profile, default_render_profile())),
    json_string(tostring(render_req and render_req.terminal_program or "")),
    parse_render_scale(render_req and render_req.terminal_scale, 1.00),
    math.max(0, tonumber(render_req and render_req.render_calc_baseline_px) or 0),
    math.max(0, tonumber(render_req and render_req.render_calc_by_cols_px) or 0),
    math.max(0, tonumber(render_req and render_req.render_calc_after_cols_px) or 0),
    math.max(0, tonumber(render_req and render_req.render_calc_after_readability_px) or 0),
    math.max(0, tonumber(render_req and render_req.render_calc_after_terminal_px) or 0),
    math.max(0, tonumber(render_req and render_req.render_calc_tmux_cap_px) or 0),
    C.clamp_tuning(tonumber(render_req and render_req.readability_zoom), readability_zoom()),
    C.clamp_tuning(tonumber(render_req and render_req.page_tallness), page_tallness_scale()),
    os.time()
  )

  prune_request_queue(root, math.max(1, queue_max_files() - 1), digest)
  local ok_queue, err_queue = C.atomic_write_file(tostring(queue_url), payload)
  if not ok_queue then
    return nil, "failed to write request queue: " .. tostring(err_queue)
  end
  C.chmod_600(tostring(queue_url))
  prune_request_queue(root, queue_max_files(), digest)

  local req_json_file = tostring(request_json_path(root))
  local ok_json, err_json = C.atomic_write_file(req_json_file, payload)
  if not ok_json then
    safe_remove_file(queue_url)
    return nil, "failed to write request json: " .. tostring(err_json)
  end
  C.chmod_600(req_json_file)

  local lock_payload = string.format(
    '{"requestedAt":%d,"requestId":%s,"path":%s}\n',
    os.time(),
    json_string(req_id),
    json_string(rel)
  )
  local ok_lock, err_lock = C.atomic_write_file(tostring(lock_url), lock_payload)
  if not ok_lock then
    safe_remove_file(queue_url)
    return nil, "failed to write lock file: " .. tostring(err_lock)
  end
  C.chmod_600(tostring(lock_url))
  write_status_snapshot(root, digest, {
    path = rel,
    request_id = req_id,
    state = "running",
    stage = "queued",
  })

  local rest_err = nil
  local cli_err = nil
  local uri_err = nil
  local allow_cli = false
  local allow_uri = false

  if use_rest() then
    local ok, rest_err_local = request_render_by_rest(rel)
    if ok then
      return true, nil
    end
    rest_err = rest_err_local

    allow_cli = cli_fallback() or (auto_cli_fallback() and should_auto_cli_fallback(rest_err))
    if allow_cli then
      maybe_notify_fallback("CLI fallback")
      local ok_cli, cli_err_local = request_render_by_cli()
      if ok_cli then
        return true, nil
      end
      cli_err = cli_err_local
    end

    allow_uri = uri_fallback() or (auto_uri_fallback() and should_auto_uri_fallback(rest_err))
    if allow_uri then
      maybe_notify_fallback("URI fallback")
      local ok_uri, uri_err_local = request_render_by_uri(rel)
      if ok_uri then
        return true, nil
      end
      uri_err = uri_err_local
    end
  else
    allow_cli = cli_fallback()
    allow_uri = uri_fallback() or auto_uri_fallback()

    if allow_cli then
      local ok_cli, cli_err_local = request_render_by_cli()
      if ok_cli then
        return true, nil
      end
      cli_err = cli_err_local
    end

    if allow_uri then
      local ok_uri, uri_err_local = request_render_by_uri(rel)
      if ok_uri then
        return true, nil
      end
      uri_err = uri_err_local
    end
  end

  -- All enabled transport paths failed (or none were enabled): remove stale lock so retry is immediate.
  safe_remove_file(queue_url)
  safe_remove_file(lock_url)

  if (not use_rest()) and (not allow_cli) and (not allow_uri) then
    write_status_snapshot(root, digest, {
      path = rel,
      request_id = req_id,
      state = "error",
      stage = "trigger-failed",
      error_message = "REST transport is disabled and no fallback is enabled",
    })
    return nil,
      "REST transport is disabled and no fallback is enabled (set OBSIDIAN_YAZI_CLI_FALLBACK=1 and/or OBSIDIAN_YAZI_URI_FALLBACK=1)"
  end

  local parts = {}
  if rest_err then
    table.insert(parts, "REST failed (" .. tostring(rest_err) .. ")")
  end
  if cli_err then
    table.insert(parts, "CLI fallback failed (" .. tostring(cli_err) .. ")")
  end
  if uri_err then
    table.insert(parts, "URI fallback failed (" .. tostring(uri_err) .. ")")
  end
  if #parts > 0 then
    write_status_snapshot(root, digest, {
      path = rel,
      request_id = req_id,
      state = "error",
      stage = "trigger-failed",
      error_message = table.concat(parts, "; "),
    })
    return nil, table.concat(parts, "; ")
  end

  write_status_snapshot(root, digest, {
    path = rel,
    request_id = req_id,
    state = "error",
    stage = "trigger-failed",
    error_message = "failed to request render via configured transports",
  })
  return nil, "failed to request render via configured transports"
end

local function digest_for_rel(rel)
  local cached = M._digest_cache[rel]
  if cached and cached.digest and cached.digest ~= "" then
    cached.at = now_seconds()
    return cached.digest
  end

  local digest = C.md5_hex(rel)
  if digest and digest ~= "" then
    remember_cache_entry(M._digest_cache, rel, { digest = digest })
  end
  return digest
end

local function context_for(file_url)
  local abs_path = C.to_path(file_url)
  local rel = C.relpath(abs_path, C.vault_root())
  if not rel then
    return nil
  end

  local digest = digest_for_rel(rel)
  local root = C.cache_root()
  if M._cache_dirs_ready_for ~= root then
    local ok, err = C.ensure_cache_dirs(root)
    if not ok then
      ya.notify({
        title = "Obsidian Preview",
        content = "Invalid cache root: " .. tostring(err),
        timeout = 2.4,
        level = "warn",
      })
      return nil
    end
    M._cache_dirs_ready_for = root
  end

  return {
    rel = rel,
    digest = digest,
    root = root,
  }
end

local function clear_transport_backoff(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  M._transport_backoff_until[key] = nil
end

local function mark_transport_backoff(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  M._transport_backoff_until[key] = now_seconds() + transport_retry_backoff_secs()
end

local function can_retry_transport(file_url, digest, opts)
  opts = opts or {}
  if opts.manual then
    return true
  end
  local key = refresh_state_key(file_url, digest)
  local retry_after = tonumber(M._transport_backoff_until[key] or 0) or 0
  if retry_after <= 0 then
    return true
  end
  if now_seconds() >= retry_after then
    M._transport_backoff_until[key] = nil
    return true
  end
  return false
end

local function clear_request_failure(file_url, digest)
  local key = refresh_state_key(file_url, digest)
  M._request_error_state[key] = nil
  clear_transport_backoff(file_url, digest)
end

local function notify_request_failure(file_url, digest, raw_err, opts)
  opts = opts or {}
  local root = tostring(opts.root or "")
  local is_manual = opts.manual and true or false
  local has_cached_image = opts.has_cached_image and true or false
  local err_message = short_text(tostring(raw_err or "unknown error"), 240)
  mark_transport_backoff(file_url, digest)
  if root ~= "" and digest ~= "" then
    local log_path = root .. "/log/" .. tostring(digest) .. ".transport.error.txt"
    local payload = string.format("%s\t%s\t%s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(file_url), err_message)
    C.atomic_write_file(log_path, payload)
    write_status_snapshot(root, digest, {
      path = tostring(file_url or ""),
      request_id = "",
      state = "error",
      stage = "trigger-failed",
      error_message = err_message,
    })
  end
  local should_notify = is_manual or verbose_refresh_notify() or (not has_cached_image)
  if not should_notify then
    return
  end
  local key = refresh_state_key(file_url, digest)
  local now = now_seconds()
  err_message = short_text(tostring(raw_err or "unknown error"), 120)
  local cached = M._request_error_state[key]
  local cooldown = is_manual and 8.0 or 5.0
  if cached and cached.err == err_message and (now - (cached.at or 0)) < cooldown then
    return
  end

  M._request_error_state[key] = {
    err = err_message,
    at = now,
  }
  ya.notify({
    title = "Obsidian Preview",
    content = "Regeneration trigger failed: " .. err_message .. " (retrying soon)",
    timeout = 2.4,
    level = "warn",
  })
end

local function maybe_notify_cache_repair(file_url, digest)
  if not show_cache_repair_notify() then
    return
  end
  local key = refresh_state_key(file_url, digest)
  local now = now_seconds()
  local last = tonumber(M._cache_repair_notice_state[key] or 0) or 0
  if (now - last) < 2.5 then
    return
  end
  M._cache_repair_notice_state[key] = now

  ya.notify({
    title = "Obsidian Preview",
    content = "Cached pages are incomplete. Rebuilding automatically...",
    timeout = 1.6,
    level = "info",
  })
end

function M:peek(job)
  if job.file.cha and job.file.cha.is_dir then
    return require("folder"):peek(job)
  end

  local force_regen = is_truthy(job.force_regen)

  -- Check for polling marker written by obsidian-refresh.
  -- This marker persists across peek restarts (touch triggers multiple peeks).
  local regen_polling_marker = false
  do
    local ctx_pre = context_for(job.file.url)
    if ctx_pre then
      local marker_url = Url(ctx_pre.root .. "/locks/" .. ctx_pre.digest .. ".regen_polling")
      local marker_cha = fs.cha(marker_url)
      if marker_cha then
        local marker_age = os.time() - (marker_cha.mtime or 0)
        if marker_age <= 120 then
          regen_polling_marker = true
          force_regen = true
        else
          safe_remove_file(marker_url)
        end
      end
    end
  end

  local tuning_regen = force_regen and (job.tune_action ~= nil)
  local manual_regen = force_regen and (not tuning_regen)
  local fast_mode = force_regen and is_truthy(job.fast_mode)

  local ctx = context_for(job.file.url)
  if not ctx then
    return show_markdown(job)
  end
  show_runtime_path_hint_once()

  local mode_url = C.mode_path(ctx.root, ctx.digest)
  if fs.cha(mode_url) then
    if tuning_regen then
      ya.notify({
        title = "Obsidian Preview Tuning",
        content = "Zoom is saved, but this note is in Markdown mode. Switch back to PNG preview to apply it.",
        timeout = 2.5,
        level = "info",
      })
    end
    return show_markdown(job)
  end

  if force_regen then
    M._tuning_cache[tostring(tuning_path(ctx.root))] = nil
  end

  local img_url = base_img_path(ctx.root, ctx.digest)
  local img_cha = fs.cha(img_url)
  local note_mtime = job.file.cha and job.file.cha.mtime
  local target_page = math.max(0, tonumber(job.skip) or 0)

  -- Fast path for page navigation (J/K): show cached page immediately to minimize flicker.
  -- Skip all layout/stale/render checks when just browsing pages.
  if not force_regen and img_cha then
    local page_url, page_idx = resolve_page_url(ctx.root, ctx.digest, job.skip)
    if page_idx == target_page then
      return show_image(job, page_url)
    end
  end

  local render_req = render_request_for_area(job.area, ctx.root, fast_mode, target_page, { bypass_cache = force_regen })

  -- Keep navigation smooth: avoid partial-page captures in browsing flow.
  if normalize_profile(render_req.render_profile, "balanced") == "fast" then
    render_req.render_profile = "balanced"
  end
  render_req.quick_mode = false
  local meta_before = read_meta_info(ctx.root, ctx.digest)
  local layout_changed = pane_layout_changed(meta_before, render_req)
  if layout_changed then
    render_req = adapt_render_request_with_meta(meta_before, render_req)
  end
  local target_page_missing = page_missing_for_request(ctx.root, ctx.digest, render_req, meta_before)
  local missing_meta = (img_cha ~= nil) and (meta_before == nil)
  local cache_incomplete = target_page_missing or missing_meta
  local stale = is_stale(img_cha, note_mtime, ctx.root, ctx.digest, render_req)
  local stale_refresh_needed = stale and target_page <= 0
  local layout_settled, layout_stable_for, _ = layout_is_settled(job.file.url, ctx.digest, job.area, render_req)
  local wait_for_layout_settle = (not force_regen) and (not layout_settled) and (img_cha ~= nil) and layout_changed
  local should_regenerate = force_regen or (img_cha == nil) or layout_changed or cache_incomplete or stale_refresh_needed
  if wait_for_layout_settle and (not cache_incomplete) and (not stale_refresh_needed) then
    should_regenerate = false
  end

  if img_cha then
    local skip = tonumber(job.skip) or 0
    local allow_refresh = force_regen
      or cache_incomplete
      or stale_refresh_needed
      or (layout_changed and layout_settled)
    local lock_url = lock_path(ctx.root, ctx.digest)
    local requested_force_regen = false

    if allow_refresh then
      if can_request_render_now(ctx.root, ctx.digest, lock_url, img_cha) then
        if cache_incomplete and (not force_regen) and (not layout_changed) then
          maybe_notify_cache_repair(job.file.url, ctx.digest)
        end
        local ok = nil
        local req_err = nil
        if can_retry_transport(job.file.url, ctx.digest, { manual = force_regen }) then
          ok, req_err = request_render(ctx.rel, ctx.digest, lock_url, ctx.root, render_req)
        end
        if ok then
          clear_request_failure(job.file.url, ctx.digest)
          if not regen_polling_marker then
            notify_refresh_started({ queued = true, queue_depth = request_queue_depth(ctx.root) })
          end
          if force_regen then
            mark_manual_refresh_pending(job.file.url, ctx.digest)
          end
        elseif req_err then
          notify_request_failure(job.file.url, ctx.digest, req_err, {
            manual = force_regen,
            root = ctx.root,
            has_cached_image = true,
          })
          if force_regen then
            clear_manual_refresh_pending(job.file.url, ctx.digest)
          end
        end
        if force_regen and ok then
          requested_force_regen = true
        end
        if ok and layout_changed and verbose_refresh_notify() then
          ya.notify({
            title = "Obsidian Preview",
            content = string.format(
              "Auto-fit pane %dx%d -> width %dpx, page %dpx.",
              math.max(0, tonumber(render_req.preview_cols) or 0),
              math.max(0, tonumber(render_req.preview_rows) or 0),
              math.max(0, tonumber(render_req.render_width_px) or 0),
              math.max(0, tonumber(render_req.page_height_px) or 0)
            ),
            timeout = 1.8,
            level = "info",
          })
        end
      end
    else
      can_request_render_now(ctx.root, ctx.digest, lock_url, img_cha)
    end

    local refreshing, refresh_state
    if manual_regen then
      -- Skip track_refresh_state for manual regen: its ya.notify fires every peek
      -- (M._refresh_state doesn't persist in async context, so throttling fails).
      -- The polling loop below handles progress display via show_refresh_overlay.
      local status = read_refresh_status(ctx.root, ctx.digest)
      refreshing = is_refresh_in_progress(ctx.root, ctx.digest, lock_url, img_cha, status)
    else
      refreshing, refresh_state = track_refresh_state(job, ctx, lock_url, img_cha, stale)
      if force_regen and requested_force_regen and not refreshing then
        local refresh_key = refresh_state_key(job.file.url, ctx.digest)
        local now_tick = now_seconds()
        local wait_state = M._refresh_state[refresh_key] or {
          active = true,
          preflight = true,
          lock_mtime = 0,
          next_poll_at = 0,
          started_at = now_tick,
          pending_skip = 0,
          stage_key = "preflight",
          last_stage = "queued",
        }
        wait_state.active = true
        wait_state.preflight = true
        wait_state.manual = true
        wait_state.started_at = (wait_state.started_at and wait_state.started_at > 0) and wait_state.started_at or now_tick
        wait_state.pending_skip = math.max(0, tonumber(skip) or 0)
        remember_cache_entry(M._refresh_state, refresh_key, wait_state)
        refreshing = true
        refresh_state = wait_state

        M._last_image_key = nil
        ya.emit("peek", { math.max(0, skip), only_if = job.file.url })
      end
    end
    if manual_regen then
      local polling_marker_url = Url(ctx.root .. "/locks/" .. ctx.digest .. ".regen_polling")
      if refreshing then
        -- Poll for render completion with overlay progress in preview pane.
        local poll_max_secs = 45
        local poll_interval = 0.6
        local poll_start = now_seconds()
        local original_mtime = img_cha and img_cha.mtime or 0
        local lock_url_poll = lock_path(ctx.root, ctx.digest)
        local lock_request_id = read_lock_request_id(lock_url_poll)
        -- Show initial progress overlay in preview pane
        show_refresh_overlay(job, refresh_progress_line(read_refresh_status(ctx.root, ctx.digest), lock_request_id, 0, ctx.root))
        while true do
          local check_cha = fs.cha(img_url)
          if check_cha and (check_cha.mtime or 0) > original_mtime then
            safe_remove_file(polling_marker_url)
            local page_url, page_idx = resolve_page_url(ctx.root, ctx.digest, job.skip)
            if page_idx ~= (tonumber(job.skip) or 0) then
              ya.emit("peek", { page_idx, only_if = job.file.url })
              return
            end
            show_image(job, page_url)
            -- Fix Kitty graphics artifact: show_refresh_overlay writes text
            -- to the preview pane's text layer. ya.image_show sends the Kitty
            -- image but may not fully redraw the area the overlay occupied.
            -- A delayed re-peek forces a clean image draw from scratch.
            local redraw_child = Command("sleep"):arg("0.5"):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
            if redraw_child then redraw_child:wait_with_output() end
            M._last_image_key = nil
            ya.image_show(page_url, job.area)
            return
          end

          local elapsed = now_seconds() - poll_start
          if elapsed >= poll_max_secs then
            break
          end

          -- Update progress overlay with spinner
          local status = read_refresh_status(ctx.root, ctx.digest)
          show_refresh_overlay(job, refresh_progress_line(status, lock_request_id, elapsed, ctx.root))

          local sleep_child = Command("sleep"):arg(tostring(poll_interval)):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
          if sleep_child then
            sleep_child:wait_with_output()
          end
        end
        -- Timeout: clean up marker and show existing image
        safe_remove_file(polling_marker_url)
        local page_url, _ = resolve_page_url(ctx.root, ctx.digest, job.skip)
        return show_image(job, page_url)
      end
      show_markdown(job, { suppress_bound_emit = true })
      return
    end

    local keep_stale_image = refreshing or show_stale_image()
    if (not should_regenerate) or keep_stale_image then
      local page_url, page_idx = resolve_page_url(ctx.root, ctx.digest, job.skip)
      if page_idx ~= (tonumber(job.skip) or 0) then
        ya.emit("peek", { page_idx, only_if = job.file.url })
      end

      local shown = show_image(job, page_url)
      if refreshing then
        maybe_poll_refresh(job, refresh_state)
      elseif wait_for_layout_settle then
        maybe_poll_layout_settle(job, job.file.url, ctx.digest)
      end
      return shown
    end
  end

  local lock_url = lock_path(ctx.root, ctx.digest)
  if (not wait_for_layout_settle)
    and can_request_render_now(ctx.root, ctx.digest, lock_url, nil)
    and can_retry_transport(job.file.url, ctx.digest, { manual = force_regen }) then
    local ok, req_err = request_render(ctx.rel, ctx.digest, lock_url, ctx.root, render_req)
    if ok then
      clear_request_failure(job.file.url, ctx.digest)
      notify_refresh_started({ queued = true, queue_depth = request_queue_depth(ctx.root) })
      if force_regen then
        mark_manual_refresh_pending(job.file.url, ctx.digest)
      end
    elseif req_err then
      notify_request_failure(job.file.url, ctx.digest, req_err, {
        manual = force_regen,
        root = ctx.root,
        has_cached_image = false,
      })
      if force_regen then
        clear_manual_refresh_pending(job.file.url, ctx.digest)
      end
    end
  end

  -- Poll for render completion within the async peek (ya.emit re-peek does not work from async context).
  local poll_max_secs = 45
  local poll_interval = 0.6
  local poll_start = now_seconds()
  while true do
    local check_cha = fs.cha(img_url)
    if check_cha then
      local page_url, page_idx = resolve_page_url(ctx.root, ctx.digest, job.skip)
      if page_idx ~= (tonumber(job.skip) or 0) then
        ya.emit("peek", { page_idx, only_if = job.file.url })
        return
      end
      return show_image(job, page_url)
    end

    local elapsed = now_seconds() - poll_start
    if elapsed >= poll_max_secs then
      break
    end

    local status = read_refresh_status(ctx.root, ctx.digest)
    local progress_line = refresh_progress_line(status, "", elapsed, ctx.root)
    show_refresh_overlay(job, progress_line)

    local sleep_child = Command("sleep"):arg(tostring(poll_interval)):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
    if sleep_child then
      sleep_child:wait_with_output()
    end
  end

  return show_markdown(job, { suppress_bound_emit = true })
end

function M:seek(job)
  local h = cx.active.current.hovered
  if not h or not h.url then
    return
  end
  local hovered_url = h.url

  local ctx = context_for(hovered_url)
  if not ctx then
    return
  end

  local current_skip = tonumber(cx.active.preview.skip) or 0
  local units = tonumber(job.units) or 0
  if units == 0 then
    return
  end

  local mode_url = C.mode_path(ctx.root, ctx.digest)
  if fs.cha(mode_url) then
    local area_h = (job.area and tonumber(job.area.h)) or 0
    local step = math.floor(units * area_h / 10)
    step = step == 0 and ya.clamp(-1, units, 1) or step
    ya.emit("peek", {
      math.max(0, current_skip + step),
    })
    return
  end

  local delta = ya.clamp(-1, units, 1)
  local meta = read_meta_info(ctx.root, ctx.digest)
  local max_skip = nil
  local total_pages = meta and tonumber(meta.page_count or 0)
  if total_pages and total_pages > 0 then
    max_skip = math.max(0, math.floor(total_pages - 1))
  end
  local next_skip = math.max(0, current_skip + delta)
  if max_skip and next_skip > max_skip then
    next_skip = max_skip
  end
  if next_skip == current_skip then
    return
  end

  -- Try to show the page image directly from seek to avoid flicker.
  -- ya.emit("peek") clears the preview pane, causing a black flash.
  local page_url, page_idx = resolve_page_url(ctx.root, ctx.digest, next_skip)
  if page_idx == next_skip then
    ya.image_show(page_url, job.area)
    ya.manager_emit("peek", { next_skip })
    return
  end

  ya.emit("peek", {
    next_skip,
  })
end

return M
