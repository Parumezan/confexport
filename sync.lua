local common = require "core.common"
local json = require "libraries.json"
local profile = require "plugins.confexport.profile"

local sync = {}

local function join(...)
  return table.concat({ ... }, PATHSEP)
end

local function normalize(path)
  return common.normalize_path(system.absolute_path(path) or path)
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function ensure_dir(path)
  local info = system.get_file_info(path)
  if info then
    return info.type == "dir" and true or nil, "not a directory: " .. path
  end
  local ok, err, failed_path = common.mkdirp(path)
  if not ok then
    return nil, string.format("%s: %s", err or "cannot create directory", failed_path or path)
  end
  return true
end

local function remove(path)
  if not system.get_file_info(path) then return true end
  local ok, err, failed_path = common.rm(path, true)
  if not ok then
    return nil, string.format("%s: %s", err or "cannot remove path", failed_path or path)
  end
  return true
end

local function safe_profile_path(value)
  value = trim(value):gsub("\\", "/"):gsub("/+", "/")
  value = value:gsub("^%./", ""):gsub("/$", "")
  if value == "" or value:find("%c") or value:sub(1, 1) == "/" or value:match("^%a:") then
    return nil, "the synchronized profile path must be relative"
  end
  for component in value:gmatch("[^/]+") do
    if component == "." or component == ".." or component == ".git" then
      return nil, "unsafe synchronized profile path: " .. value
    end
  end
  return value
end

local function options_from(values)
  values = values or {}
  local relative, err = safe_profile_path(values.sync_profile or "lite-xl-profile")
  if not relative then return nil, err end
  local repository = trim(values.sync_repository)
  if repository:match("://[^/%s]+:[^@/%s]+@") then
    return nil, "repository URLs containing credentials are refused; use a Git credential manager or SSH agent"
  end
  local directory = trim(values.sync_directory)
  if directory == "" then return nil, "no local synchronization directory is configured" end
  local branch = trim(values.sync_branch) ~= "" and trim(values.sync_branch) or "main"
  if branch:find("[%c%s~^:?*%[]") or branch:find("..", 1, true)
    or branch:find("\\", 1, true) or branch:find("@{", 1, true)
    or branch:find("//", 1, true) or branch:sub(1, 1) == "-"
    or branch:sub(-1) == "." or branch:sub(-1) == "/"
  then
    return nil, "unsafe Git branch name: " .. branch
  end
  return {
    repository = repository,
    branch = branch,
    directory = normalize(directory),
    profile_relative = relative,
    profile_path = join(normalize(directory), (relative:gsub("/", PATHSEP))),
    commit_message = trim(values.sync_commit_message) ~= ""
      and trim(values.sync_commit_message) or "Update Lite XL configuration",
    secret_exclusions = type(values.sync_secret_exclusions) == "table"
      and values.sync_secret_exclusions or {},
    block_on_secrets = values.sync_block_on_secrets ~= false
  }
end

sync.options = options_from

local function git(run, root, arguments)
  local command = { "git" }
  if root then
    command[#command + 1] = "-C"
    command[#command + 1] = root
  end
  for _, argument in ipairs(arguments) do command[#command + 1] = argument end
  return run(command)
end

local function repo_exists(root)
  local info = system.get_file_info(join(root, ".git"))
  return info and (info.type == "dir" or info.type == "file")
end

local function directory_is_empty(path)
  local info = system.get_file_info(path)
  return not info or (info.type == "dir" and #(system.list_dir(path) or {}) == 0)
end

local function require_clean(options, run)
  local output, err = git(run, options.directory, {
    "status", "--porcelain=v1", "--untracked-files=all"
  })
  if not output then return nil, "cannot inspect Git status: " .. tostring(err) end
  if trim(output) ~= "" then
    return nil, "the synchronization repository contains uncommitted changes; resolve them before continuing"
  end
  return true
end

local function has_ref(options, run, reference)
  return git(run, options.directory, { "rev-parse", "--verify", "--quiet", reference }) ~= nil
end

local function current_branch(options, run)
  local output = git(run, options.directory, { "branch", "--show-current" })
  return output and trim(output) or ""
end

local function divergence(options, run)
  local local_head = has_ref(options, run, "HEAD")
  local remote_ref = "refs/remotes/origin/" .. options.branch
  local remote_head = has_ref(options, run, remote_ref)
  if not local_head or not remote_head then
    return { local_head = local_head, remote_head = remote_head, ahead = 0, behind = 0 }
  end
  local output, err = git(run, options.directory, {
    "rev-list", "--left-right", "--count", "HEAD..." .. remote_ref
  })
  if not output then return nil, err end
  local ahead, behind = output:match("(%d+)%s+(%d+)")
  if not ahead then return nil, "cannot understand Git divergence information" end
  return {
    local_head = true,
    remote_head = true,
    ahead = tonumber(ahead),
    behind = tonumber(behind)
  }
end

local function check_branch(options, run)
  local branch = current_branch(options, run)
  if branch ~= "" and branch ~= options.branch then
    return nil, string.format(
      "the repository is on branch '%s', but confexport is configured for '%s'",
      branch, options.branch
    )
  end
  return true
end

function sync.setup(values, run)
  local options, err = options_from(values)
  if not options then return nil, err end
  if options.repository == "" then return nil, "no synchronization repository is configured" end
  local version
  version, err = git(run, nil, { "--version" })
  if not version then return nil, "Git is not available: " .. tostring(err) end

  local info = system.get_file_info(options.directory)
  if info and info.type ~= "dir" then
    return nil, "the synchronization path is not a directory: " .. options.directory
  end
  if not repo_exists(options.directory) then
    if not directory_is_empty(options.directory) then
      return nil, "the synchronization directory exists, is not empty, and is not a Git repository"
    end
    local parent = common.dirname(options.directory)
    local ok
    ok, err = ensure_dir(parent)
    if not ok then return nil, err end
    local output
    output, err = git(run, nil, { "clone", options.repository, options.directory })
    if not output then return nil, "cannot clone the repository: " .. tostring(err) end
  end

  local origin
  origin, err = git(run, options.directory, { "remote", "get-url", "origin" })
  if not origin then
    local output
    output, err = git(run, options.directory, { "remote", "add", "origin", options.repository })
    if not output then return nil, "cannot configure the origin remote: " .. tostring(err) end
  elseif trim(origin) ~= options.repository then
    return nil, string.format(
      "origin points to '%s', not to the configured repository '%s'",
      trim(origin), options.repository
    )
  end

  local output
  output, err = git(run, options.directory, { "fetch", "origin" })
  if not output then return nil, "cannot fetch origin: " .. tostring(err) end
  local remote_ref = "refs/remotes/origin/" .. options.branch
  local branch = current_branch(options, run)
  if branch ~= options.branch then
    if has_ref(options, run, "refs/heads/" .. options.branch) then
      output, err = git(run, options.directory, { "checkout", options.branch })
    elseif has_ref(options, run, remote_ref) then
      output, err = git(run, options.directory, {
        "checkout", "-b", options.branch, "--track", "origin/" .. options.branch
      })
    elseif not has_ref(options, run, "HEAD") then
      output, err = git(run, options.directory, { "checkout", "-B", options.branch })
    else
      output, err = git(run, options.directory, { "checkout", "-b", options.branch })
    end
    if not output then return nil, "cannot select the configured branch: " .. tostring(err) end
  end
  return { options = options, git_version = trim(version) }
end

function sync.status(values, run)
  local options, err = options_from(values)
  if not options then return nil, err end
  if not repo_exists(options.directory) then
    return nil, "the synchronization repository is not initialized; run confexport:sync-setup"
  end
  local porcelain
  porcelain, err = git(run, options.directory, {
    "status", "--porcelain=v1", "--untracked-files=all"
  })
  if not porcelain then return nil, err end
  local remote = git(run, options.directory, { "remote", "get-url", "origin" })
  local state, divergence_error = divergence(options, run)
  if not state then return nil, divergence_error end
  return {
    options = options,
    branch = current_branch(options, run),
    remote = remote and trim(remote) or nil,
    clean = trim(porcelain) == "",
    changes = trim(porcelain),
    ahead = state.ahead,
    behind = state.behind,
    remote_head = state.remote_head,
    local_head = state.local_head,
    profile_exists = system.get_file_info(options.profile_path) ~= nil
  }
end

local function push_preflight(options, run)
  if not repo_exists(options.directory) then
    return nil, "the synchronization repository is not initialized; run confexport:sync-setup"
  end
  local ok, err = require_clean(options, run)
  if not ok then return nil, err end
  ok, err = check_branch(options, run)
  if not ok then return nil, err end
  local output
  output, err = git(run, options.directory, { "fetch", "origin" })
  if not output then return nil, "cannot fetch origin: " .. tostring(err) end
  local state
  state, err = divergence(options, run)
  if not state then return nil, err end
  if not state.local_head and state.remote_head then
    return nil, "the remote branch already contains history; run confexport:sync-pull first"
  end
  if state.behind > 0 then
    return nil, "the remote branch contains changes; run confexport:sync-pull before pushing"
  end
  return state
end

local function files(root, relative, result)
  result = result or {}
  local path = relative == "" and root or join(root, (relative:gsub("/", PATHSEP)))
  local info = system.get_file_info(path)
  if not info then return result end
  if info.type == "file" then
    result[relative] = path
  elseif info.type == "dir" then
    local entries = system.list_dir(path) or {}
    table.sort(entries)
    for _, name in ipairs(entries) do
      files(root, relative == "" and name or (relative .. "/" .. name), result)
    end
  end
  return result
end

local function read_all(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local data = fp:read("*a")
  fp:close()
  return data
end

local function deep_equal(left, right, seen)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  seen = seen or {}
  if seen[left] == right then return true end
  seen[left] = right
  for key, value in pairs(left) do
    if not deep_equal(value, right[key], seen) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function same_manifest(first, second)
  local first_data, second_data = read_all(first), read_all(second)
  if not first_data or not second_data then return false end
  local ok_first, first_manifest = pcall(json.decode, first_data)
  local ok_second, second_manifest = pcall(json.decode, second_data)
  if not ok_first or not ok_second then return false end
  first_manifest.created_at = nil
  second_manifest.created_at = nil
  return deep_equal(first_manifest, second_manifest)
end

local function same_file(first, second, relative)
  if relative == "manifest.json" then return same_manifest(first, second) end
  local a, b = io.open(first, "rb"), io.open(second, "rb")
  if not a or not b then
    if a then a:close() end
    if b then b:close() end
    return false
  end
  while true do
    local left, right = a:read(65536), b:read(65536)
    if left ~= right then a:close() b:close() return false end
    if not left then a:close() b:close() return true end
  end
end

local function compare_trees(old_root, new_root)
  local old_files = system.get_file_info(old_root) and files(old_root, "") or {}
  local new_files = files(new_root, "")
  local names, changes = {}, {}
  for name in pairs(old_files) do names[name] = true end
  for name in pairs(new_files) do names[name] = true end
  local sorted = {}
  for name in pairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    if not old_files[name] then
      changes[#changes + 1] = { status = "A", path = name }
    elseif not new_files[name] then
      changes[#changes + 1] = { status = "D", path = name }
    elseif not same_file(old_files[name], new_files[name], name) then
      changes[#changes + 1] = { status = "M", path = name }
    end
  end
  return changes
end

local secret_rules = {
  { name = "private key", pattern = "BEGIN [%u ]-PRIVATE KEY" },
  { name = "credential in URL", pattern = "://[^/%s]+:[^@/%s]+@" },
  { name = "GitHub token", pattern = "gh[pousr]_[%w_%-]+" },
  { name = "AWS access key", pattern = "AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]" },
  { name = "probable token assignment", pattern = "[%w_%-]*token[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" },
  { name = "probable secret assignment", pattern = "[%w_%-]*secret[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" },
  { name = "probable password assignment", pattern = "[%w_%-]*password[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" },
  { name = "probable password assignment", pattern = "[%w_%-]*passwd[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" },
  { name = "probable API key assignment", pattern = "[%w_%-]*api[_%-]?key[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" },
  { name = "probable private key assignment", pattern = "[%w_%-]*private[_%-]?key[%w_%-]*%s*[=:]%s*['\"][^'\"]+['\"]" }
}

local function excluded_set(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[tostring(value):gsub("\\", "/"):gsub("^%./", "")] = true
  end
  return result
end

function sync.scan_secrets(root, exclusions)
  local result, ignored = {}, excluded_set(exclusions)
  for _, relative in ipairs { "init.lua", "user_settings.lua", "manifest.json" } do
    if not ignored[relative] then
      local path = join(root, relative)
      local fp = io.open(path, "r")
      if fp then
        local line_number = 0
        for line in fp:lines() do
          line_number = line_number + 1
          local lower = line:lower()
          for _, rule in ipairs(secret_rules) do
            local subject = rule.name:match("^probable") and lower or line
            if subject:match(rule.pattern) then
              result[#result + 1] = {
                file = relative,
                line = line_number,
                rule = rule.name
              }
              break
            end
          end
        end
        fp:close()
      end
    end
  end
  return result
end

local function unique_temporary(root, prefix)
  local base = join(root, prefix .. os.date("%Y%m%d-%H%M%S"))
  local result, index = base, 2
  while system.get_file_info(result) do
    result = base .. "-" .. index
    index = index + 1
  end
  return result
end

function sync.prepare_push(values, inventory, export_options, run)
  local options, err = options_from(values)
  if not options then return nil, err end
  local state
  state, err = push_preflight(options, run)
  if not state then return nil, err end
  local staging = unique_temporary(
    common.dirname(options.directory),
    ".confexport-staging-"
  )
  local exported
  exported, err = profile.export(staging, inventory, export_options)
  if not exported then return nil, err end
  return {
    options = options,
    staging = staging,
    changes = compare_trees(options.profile_path, staging),
    secrets = sync.scan_secrets(staging, options.secret_exclusions),
    ahead = state.ahead
  }
end

function sync.cancel_push(transaction)
  return remove(transaction.staging)
end

local function restore_after_failure(transaction, previous, run)
  local options = transaction.options
  remove(options.profile_path)
  if previous and system.get_file_info(previous) then os.rename(previous, options.profile_path) end
  if has_ref(options, run, "HEAD") then
    git(run, options.directory, { "reset", "HEAD", "--", options.profile_relative })
  else
    git(run, options.directory, {
      "rm", "--cached", "-r", "--ignore-unmatch", "--", options.profile_relative
    })
  end
end

function sync.commit_push(transaction, run)
  local options = transaction.options
  local state, err = push_preflight(options, run)
  if not state then sync.cancel_push(transaction) return nil, err end

  if #transaction.changes == 0 then
    sync.cancel_push(transaction)
    if state.ahead > 0 then
      local output
      output, err = git(run, options.directory, {
        "push", "--set-upstream", "origin", options.branch
      })
      if not output then return nil, "cannot push existing commits: " .. tostring(err) end
      return { committed = false, pushed = true, unchanged = true }
    end
    return { committed = false, pushed = false, unchanged = true }
  end

  local identity
  identity, err = git(run, options.directory, { "var", "GIT_AUTHOR_IDENT" })
  if not identity then
    sync.cancel_push(transaction)
    return nil, "Git author identity is not configured: " .. tostring(err)
  end

  local parent = common.dirname(options.profile_path)
  local ok
  ok, err = ensure_dir(parent)
  if not ok then sync.cancel_push(transaction) return nil, err end
  local previous
  if system.get_file_info(options.profile_path) then
    previous = unique_temporary(options.directory, ".confexport-previous-")
    local renamed, rename_error = os.rename(options.profile_path, previous)
    if not renamed then sync.cancel_push(transaction) return nil, rename_error end
  end
  local renamed, rename_error = os.rename(transaction.staging, options.profile_path)
  if not renamed then
    if previous then os.rename(previous, options.profile_path) end
    sync.cancel_push(transaction)
    return nil, rename_error or "cannot install the exported profile in the repository"
  end

  local output
  output, err = git(run, options.directory, {
    "add", "--all", "--", options.profile_relative
  })
  if not output then
    restore_after_failure(transaction, previous, run)
    return nil, "cannot stage the exported profile: " .. tostring(err)
  end
  output, err = git(run, options.directory, {
    "commit", "-m", options.commit_message, "--", options.profile_relative
  })
  if not output then
    restore_after_failure(transaction, previous, run)
    return nil, "cannot commit the exported profile: " .. tostring(err)
  end
  if previous then remove(previous) end

  output, err = git(run, options.directory, {
    "push", "--set-upstream", "origin", options.branch
  })
  if not output then
    return nil, "the profile was committed locally, but the push failed: " .. tostring(err)
  end
  return { committed = true, pushed = true, unchanged = false }
end

function sync.pull(values, run)
  local options, err = options_from(values)
  if not options then return nil, err end
  if not repo_exists(options.directory) then
    return nil, "the synchronization repository is not initialized; run confexport:sync-setup"
  end
  local ok
  ok, err = require_clean(options, run)
  if not ok then return nil, err end
  ok, err = check_branch(options, run)
  if not ok then return nil, err end
  local output
  output, err = git(run, options.directory, { "fetch", "origin" })
  if not output then return nil, "cannot fetch origin: " .. tostring(err) end
  local state
  state, err = divergence(options, run)
  if not state then return nil, err end
  if not state.remote_head then return nil, "the configured remote branch does not exist" end
  if state.ahead > 0 and state.behind > 0 then
    return nil, "local and remote histories have diverged; resolve the Git conflict manually"
  end
  if not state.local_head then
    output, err = git(run, options.directory, {
      "checkout", "-B", options.branch, "origin/" .. options.branch
    })
  elseif state.behind > 0 then
    output, err = git(run, options.directory, {
      "merge", "--ff-only", "origin/" .. options.branch
    })
  end
  if (not state.local_head or state.behind > 0) and not output then
    return nil, "cannot fast-forward the synchronization repository: " .. tostring(err)
  end
  if not system.get_file_info(options.profile_path) then
    return nil, "the synchronized repository does not contain the configured confexport profile"
  end
  return {
    options = options,
    profile_path = options.profile_path,
    updated = not state.local_head or state.behind > 0,
    ahead = state.ahead
  }
end

return sync