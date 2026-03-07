--- obsidian-common: shared utilities for obsidian-yazi-render plugins

local C = {}

-- ---------------------------------------------------------------------------
-- Module-level caches
-- ---------------------------------------------------------------------------
local _is_darwin_cache = nil

-- ---------------------------------------------------------------------------
-- Utility primitives
-- ---------------------------------------------------------------------------

function C.env(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

function C.is_true(value)
  return value ~= nil and value ~= "" and value ~= "0" and value ~= "false" and value ~= "FALSE"
end

function C.is_truthy(value)
  if value == nil or value == false then
    return false
  end
  if value == true then
    return true
  end
  return C.is_true(tostring(value))
end

function C.to_int(raw, fallback)
  local num = tonumber(raw)
  if not num then
    return fallback
  end
  return math.floor(num)
end

function C.clamp(min_v, value, max_v)
  if value < min_v then
    return min_v
  end
  if value > max_v then
    return max_v
  end
  return value
end

-- ---------------------------------------------------------------------------
-- Path utilities
-- ---------------------------------------------------------------------------

function C.user_home()
  local home = tostring(os.getenv("HOME") or "")
  if home ~= "" then
    return home
  end
  return tostring(os.getenv("USERPROFILE") or "")
end

function C.is_darwin()
  if _is_darwin_cache ~= nil then
    return _is_darwin_cache
  end

  local child = Command("uname")
    :arg("-s")
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()
  if child then
    local output = child:wait_with_output()
    if output and output.status.success then
      local name = tostring(output.stdout or ""):gsub("%s+$", ""):lower()
      if name == "darwin" then
        _is_darwin_cache = true
        return true
      end
      if name ~= "" then
        _is_darwin_cache = false
        return false
      end
    end
  end

  local ostype = tostring(os.getenv("OSTYPE") or ""):lower()
  local result = ostype:find("darwin", 1, true) ~= nil
  _is_darwin_cache = result
  return result
end

function C.default_cache_root()
  local home = C.user_home()

  if C.is_darwin() then
    if home ~= "" then
      return home .. "/Library/Caches/obsidian-yazi"
    end
    return "/tmp/obsidian-yazi"
  end

  local xdg = tostring(os.getenv("XDG_CACHE_HOME") or "")
  if xdg ~= "" then
    return xdg .. "/obsidian-yazi"
  end

  if home ~= "" then
    return home .. "/.cache/obsidian-yazi"
  end

  return "/tmp/obsidian-yazi"
end

function C.cache_root()
  local raw = C.env("OBSIDIAN_YAZI_CACHE", C.default_cache_root())
  local home = C.user_home()

  -- Handle bare "~"
  if raw == "~" and home ~= "" then
    return home
  end

  -- Handle "~/" and "~\" prefixes
  if raw:sub(1, 2) == "~/" or raw:sub(1, 2) == "~\\" then
    if home ~= "" then
      return home .. raw:sub(2)
    end
  end

  return raw
end

function C.vault_root()
  local home = C.user_home()
  local default = (home ~= "") and (home .. "/obsidian") or "/obsidian"
  local raw = C.env("OBSIDIAN_VAULT_ROOT", default)

  if raw == "~" and home ~= "" then
    return home
  end
  if raw:sub(1, 2) == "~/" or raw:sub(1, 2) == "~\\" then
    if home ~= "" then
      return home .. raw:sub(2)
    end
  end

  return raw
end

function C.normalize_path(path)
  return path:gsub("\\", "/")
end

function C.to_path(url)
  local path = tostring(url)
  path = path:gsub("^file://", "")
  return C.normalize_path(path)
end

function C.relpath(abs_path, root)
  abs_path = C.normalize_path(abs_path)
  root = C.normalize_path(root)
  -- Strip trailing slashes but preserve filesystem root "/"
  if #root > 1 then
    root = root:gsub("/+$", "")
  end

  if abs_path == root then
    return nil
  end
  if abs_path:sub(1, #root + 1) ~= (root .. "/") then
    return nil
  end

  local rel = abs_path:sub(#root + 1)
  if rel:sub(1, 1) == "/" then
    rel = rel:sub(2)
  end

  if rel == "" then
    return nil
  end
  return rel
end

-- ---------------------------------------------------------------------------
-- Hashing
-- ---------------------------------------------------------------------------

function C.md5_hex(raw)
  local function is_md5_hex(text)
    local v = tostring(text or "")
    return #v == 32 and v:match("^[A-Fa-f0-9]+$") ~= nil
  end

  local child, spawn_err = Command("md5")
    :arg("-q")
    :arg("-s")
    :arg(raw)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()

  if child then
    local output, _wait_err = child:wait_with_output()
    if output and output.status.success then
      local digest = output.stdout:gsub("%s+$", "")
      if is_md5_hex(digest) then
        return digest, nil
      end
    end
  end

  -- Linux often ships md5sum instead of md5.
  local shell_child, shell_spawn_err = Command("sh")
    :arg("-c")
    :arg("printf '%s' \"$1\" | md5sum | awk '{print $1}'")
    :arg("obsidian-yazi")
    :arg(raw)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()

  if shell_child then
    local shell_output, shell_wait_err = shell_child:wait_with_output()
    if shell_output and shell_output.status.success then
      local digest = shell_output.stdout:gsub("%s+$", "")
      if is_md5_hex(digest) then
        return digest, nil
      end
    elseif shell_output and shell_output.stderr ~= "" then
      shell_wait_err = shell_output.stderr
    end

    if shell_wait_err and shell_wait_err ~= "" then
      return ya.hash(raw), shell_wait_err
    end
  end

  local fallback_err = shell_spawn_err or spawn_err or "md5 command is unavailable"
  return ya.hash(raw), fallback_err
end

-- ---------------------------------------------------------------------------
-- Security
-- ---------------------------------------------------------------------------

function C.is_safe_cache_root(root)
  local raw = tostring(root or "")
  local p = raw:gsub("\\", "/"):gsub("/+$", "")
  if p == "" then
    return false
  end
  if raw:sub(1, 1) ~= "/" and raw:match("^%a:[/\\]") == nil and raw:sub(1, 2) ~= "\\\\" then
    return false
  end
  if p == "/" or p == "." then
    return false
  end
  local home = C.user_home():gsub("\\", "/"):gsub("/+$", "")
  if home ~= "" and p == home then
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- File operations
-- ---------------------------------------------------------------------------

function C.chmod_700(path)
  local child = Command("chmod")
    :arg("700")
    :arg(path)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()
  if child then
    child:wait_with_output()
  end
end

function C.chmod_600(path)
  local child = Command("chmod")
    :arg("600")
    :arg(path)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()
  if not child then
    return nil, "failed to spawn chmod"
  end

  local output, wait_err = child:wait_with_output()
  if not output then
    return nil, wait_err
  end
  if not output.status.success then
    return nil, output.stderr ~= "" and output.stderr or "chmod failed"
  end

  return true, nil
end

function C.safe_remove_file(path_or_url)
  local url = path_or_url
  if type(path_or_url) == "string" then
    url = Url(path_or_url)
  end
  if url then
    pcall(fs.remove, "file", url)
  end
end

function C.atomic_write_file(path, content)
  local tmp = string.format("%s.tmp.%d.%d", path, os.time(), math.random(100000, 999999))
  fs.write(Url(tmp), content)
  -- best-effort chmod: don't block the write if chmod fails
  C.chmod_600(tmp)

  local child, spawn_err = Command("mv")
    :arg("-f")
    :arg(tmp)
    :arg(path)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :spawn()
  if not child then
    C.safe_remove_file(tmp)
    return nil, spawn_err or "failed to spawn mv"
  end

  local output, wait_err = child:wait_with_output()
  if not output then
    C.safe_remove_file(tmp)
    return nil, wait_err
  end

  if not output.status.success then
    C.safe_remove_file(tmp)
    return nil, output.stderr ~= "" and output.stderr or "mv failed"
  end

  return true, nil
end

function C.run_capture(cmd, args)
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
    return nil, output.stderr ~= "" and output.stderr or ("exit code " .. tostring(output.status.code))
  end

  return output.stdout, nil
end

function C.run_capture_with_stdin(cmd, args, stdin_payload)
  local runner = Command(cmd)
  for _, arg in ipairs(args) do
    runner:arg(arg)
  end

  local child, spawn_err = runner:stdin(Command.PIPED):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
  if not child then
    return nil, spawn_err
  end

  local ok_write, write_err = child:write_all(stdin_payload or "")
  if not ok_write then
    local output, wait_err = child:wait_with_output()
    if wait_err then
      return nil, wait_err
    end
    if output and output.stderr ~= "" then
      return nil, output.stderr
    end
    return nil, write_err or "failed to write stdin"
  end

  local output, wait_err = child:wait_with_output()
  if not output then
    return nil, wait_err
  end

  if not output.status.success then
    return nil, output.stderr ~= "" and output.stderr or ("exit code " .. tostring(output.status.code))
  end

  return output.stdout, nil
end

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------

function C.json_string(raw)
  local s = tostring(raw or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\"", "\\\"")
  s = s:gsub("\b", "\\b")
  s = s:gsub("\f", "\\f")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  s = s:gsub("[%z\1-\31]", function(ch)
    return string.format("\\u%04x", string.byte(ch))
  end)
  return "\"" .. s .. "\""
end

function C.short_text(raw, max_len)
  local text = tostring(raw or "")
  if #text <= max_len then
    return text
  end
  return text:sub(1, max_len) .. "..."
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

function C.now_seconds()
  local t = ya.time()
  if type(t) == "number" and t > 0 then
    return t
  end
  return os.time()
end

-- ---------------------------------------------------------------------------
-- Path builders (shared across nav / preview / toggle / tune)
-- ---------------------------------------------------------------------------

function C.mode_path(root, digest)
  return Url(root .. "/mode/" .. digest .. ".md")
end

function C.meta_path(root, digest)
  return Url(root .. "/img/" .. digest .. ".meta.json")
end

function C.page_img_path(root, digest, page)
  return Url(root .. "/img/" .. digest .. string.format("--p%04d.png", page))
end

function C.ensure_mode_dir(root)
  fs.create("dir_all", Url(root .. "/mode"))
  C.chmod_700(root)
  C.chmod_700(root .. "/mode")
end

-- ---------------------------------------------------------------------------
-- Tuning constants
-- ---------------------------------------------------------------------------

C.TUNING_MIN = 0.70
C.TUNING_MAX = 2.40

function C.clamp_tuning(value, fallback)
  local n = tonumber(value)
  if not n then
    return fallback
  end
  return C.clamp(C.TUNING_MIN, n, C.TUNING_MAX)
end

-- ---------------------------------------------------------------------------
-- Cache directory management
-- ---------------------------------------------------------------------------

function C.ensure_cache_dirs(root)
  if not C.is_safe_cache_root(root) then
    return nil, "unsafe cache root: " .. tostring(root)
  end

  fs.create("dir_all", Url(root .. "/img"))
  fs.create("dir_all", Url(root .. "/mode"))
  fs.create("dir_all", Url(root .. "/locks"))
  fs.create("dir_all", Url(root .. "/log"))
  fs.create("dir_all", Url(root .. "/requests"))
  fs.create("dir_all", Url(root .. "/requests/queue"))

  C.chmod_700(root)
  C.chmod_700(root .. "/img")
  C.chmod_700(root .. "/mode")
  C.chmod_700(root .. "/locks")
  C.chmod_700(root .. "/log")
  C.chmod_700(root .. "/requests")
  C.chmod_700(root .. "/requests/queue")
  fs.write(Url(root .. "/.obsidian-yazi-cache"), "obsidian-yazi-cache\n")

  local sentinel = root .. "/.obsidian-yazi-cache"
  C.chmod_600(sentinel)

  return true, nil
end

return C
