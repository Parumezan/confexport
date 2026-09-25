-- mod-version:3 --lite-xl 2.1

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local json = require "libraries.json"
local profile = require "plugins.confexport.profile"
local sync = require "plugins.confexport.sync"

local confexport = {}
confexport.VERSION = profile.VERSION

local RECENT_REPOSITORIES_LIMIT = 8
local RECENT_REPOSITORIES_PATH = table.concat({
  USERDIR, ".confexport", "repositories.json"
}, PATHSEP)

config.plugins.confexport = common.merge({
  export_directory = USERDIR .. PATHSEP .. "exports",
  include_bootstrap = true,
  include_colors = true,
  include_custom_plugins = true,
  include_custom_libraries = true,
  create_backup = true,
  sync_repository = "",
  sync_branch = "main",
  sync_directory = USERDIR .. PATHSEP .. "sync" .. PATHSEP .. "confexport",
  sync_profile = "lite-xl-profile",
  sync_commit_message = "Update Lite XL configuration",
  sync_secret_exclusions = {},
  sync_block_on_secrets = true,
  config_spec = {
    name = "Configuration Export",
    {
      label = "Export Directory",
      description = "Default directory used to create portable configuration profiles.",
      path = "export_directory",
      type = "directory",
      default = USERDIR .. PATHSEP .. "exports"
    },
    {
      label = "Include Bootstrap",
      description = "Add an optional, self-contained Lua entry point for importing on a new installation.",
      path = "include_bootstrap",
      type = "toggle",
      default = true
    },
    {
      label = "Include Color Schemes",
      description = "Export color schemes not managed by LPM into the profile's colors directory.",
      path = "include_colors",
      type = "toggle",
      default = true
    },
    {
      label = "Include Custom Plugins",
      description = "Export plugins that are not managed by LPM.",
      path = "include_custom_plugins",
      type = "toggle",
      default = true
    },
    {
      label = "Include Custom Libraries",
      description = "Export libraries that are not managed by LPM.",
      path = "include_custom_libraries",
      type = "toggle",
      default = true
    },
    {
      label = "Backup Before Import",
      description = "Create a restorable backup before replacing local files.",
      path = "create_backup",
      type = "toggle",
      default = true
    },
    {
      label = "Sync Repository",
      description = "Git remote URL. Authentication is delegated to Git and is never stored by confexport.",
      path = "sync_repository",
      type = "string",
      default = ""
    },
    {
      label = "Sync Branch",
      description = "Git branch used for configuration synchronization.",
      path = "sync_branch",
      type = "string",
      default = "main"
    },
    {
      label = "Sync Directory",
      description = "Local clone used by confexport.",
      path = "sync_directory",
      type = "directory",
      default = USERDIR .. PATHSEP .. "sync" .. PATHSEP .. "confexport"
    },
    {
      label = "Sync Profile Path",
      description = "Relative directory containing the confexport profile inside the Git repository.",
      path = "sync_profile",
      type = "string",
      default = "lite-xl-profile"
    },
    {
      label = "Sync Commit Message",
      description = "Commit message used when pushing a new configuration snapshot.",
      path = "sync_commit_message",
      type = "string",
      default = "Update Lite XL configuration"
    },
    {
      label = "Secret Scan Exclusions",
      description = "Profile-relative files excluded from the pre-push secret scan.",
      path = "sync_secret_exclusions",
      type = "list_strings",
      default = {}
    },
    {
      label = "Block Push on Suspected Secrets",
      description = "Refuse a push when credentials may be present in exported settings.",
      path = "sync_block_on_secrets",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.confexport)

local function lpm_binary()
  local plugin_config = config.plugins.plugin_manager
  if type(plugin_config) == "table" and plugin_config.lpm_binary_path then
    return plugin_config.lpm_binary_path
  end
  local extension = PLATFORM == "Windows" and ".exe"
    or (PLATFORM == "Android" and ".so" or "")
  local names = { "lpm." .. tostring(rawget(_G, "ARCH") or "") .. extension,
    "lpm" .. extension }
  for _, root in ipairs {
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager",
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "plugin_manager"
  } do
    for _, name in ipairs(names) do
      local candidate = root .. PATHSEP .. name
      if system.get_file_info(candidate) then return candidate end
    end
  end
  return names[2]
end

local function lpm_command(arguments)
  local result = {
    lpm_binary(),
    "--json",
    "--quiet",
    "--userdir=" .. USERDIR,
    "--datadir=" .. DATADIR,
    "--binary=" .. EXEFILE,
    "--mod-version=" .. tostring(rawget(_G, "MOD_VERSION") or "3")
  }
  for _, argument in ipairs(arguments) do result[#result + 1] = argument end
  return result
end

local function drain(process_handle, method)
  local chunks = {}
  while true do
    local chunk = process_handle[method](process_handle, 8192)
    if not chunk or #chunk == 0 then break end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

local function run_process(arguments)
  local ok, process_handle = pcall(process.start, arguments)
  if not ok then return nil, tostring(process_handle) end
  local stdout, stderr = {}, {}
  while process_handle:running() do
    local output = drain(process_handle, "read_stdout")
    local errors = drain(process_handle, "read_stderr")
    if #output > 0 then stdout[#stdout + 1] = output end
    if #errors > 0 then stderr[#stderr + 1] = errors end
    coroutine.yield(0.05)
  end
  stdout[#stdout + 1] = drain(process_handle, "read_stdout")
  stderr[#stderr + 1] = drain(process_handle, "read_stderr")
  local output = table.concat(stdout)
  local errors = table.concat(stderr)
  if process_handle:returncode() ~= 0 then
    return nil, errors ~= "" and errors or output
  end
  return output, errors
end

local function run_lpm(arguments)
  return run_process(lpm_command(arguments))
end

local function decode_lpm(output, operation)
  local ok, decoded = pcall(json.decode, output)
  if not ok then
    return nil, string.format("invalid LPM response during %s: %s", operation, decoded)
  end
  return decoded
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function load_recent_repositories()
  local fp = io.open(RECENT_REPOSITORIES_PATH, "rb")
  if not fp then return {} end
  local data = fp:read("*a")
  fp:close()
  local ok, decoded = pcall(json.decode, data)
  if not ok or type(decoded) ~= "table" then return {} end

  local values = type(decoded.repositories) == "table" and decoded.repositories or decoded
  local repositories, seen = {}, {}
  for _, value in ipairs(values) do
    local repository = type(value) == "string" and trim(value) or ""
    if repository ~= "" and not seen[repository]
      and not repository:match("://[^/%s]+:[^@/%s]+@")
    then
      repositories[#repositories + 1] = repository
      seen[repository] = true
      if #repositories == RECENT_REPOSITORIES_LIMIT then break end
    end
  end
  return repositories
end

local function save_recent_repositories(repositories)
  local ok, err, failed_path = common.mkdirp(common.dirname(RECENT_REPOSITORIES_PATH))
  if not ok then return nil, err or ("cannot create " .. tostring(failed_path)) end
  local fp, open_error = io.open(RECENT_REPOSITORIES_PATH, "wb")
  if not fp then return nil, open_error end
  local wrote, write_error = fp:write(json.encode({ repositories = repositories }), "\n")
  fp:close()
  if not wrote then return nil, write_error end
  return true
end

local function remember_repository(repository)
  repository = trim(repository)
  if repository == "" or repository:match("://[^/%s]+:[^@/%s]+@") then return end
  local repositories = { repository }
  for _, previous in ipairs(load_recent_repositories()) do
    if previous ~= repository and #repositories < RECENT_REPOSITORIES_LIMIT then
      repositories[#repositories + 1] = previous
    end
  end
  local ok, err = save_recent_repositories(repositories)
  if not ok then
    core.warn("Confexport: cannot save recent Git repositories: %s", tostring(err))
  end
end

local function repository_suggestions(text)
  local repositories = load_recent_repositories()
  if trim(text) == "" then return repositories end
  return common.fuzzy_match(repositories, text)
end

local function load_inventory()
  local repository_output, err = run_lpm { "repo", "list" }
  if not repository_output then return nil, "cannot list LPM repositories: " .. tostring(err) end
  local repositories
  repositories, err = decode_lpm(repository_output, "repository listing")
  if not repositories then return nil, err end

  local addon_output
  addon_output, err = run_lpm { "list" }
  if not addon_output then return nil, "cannot list LPM addons: " .. tostring(err) end
  local addons
  addons, err = decode_lpm(addon_output, "addon listing")
  if not addons then return nil, err end
  return {
    repositories = repositories.repositories or {},
    addons = addons.addons or {}
  }
end

local function normalize_input(text, item)
  local value = item and (item.text or item) or text
  value = common.home_expand(value)
  return system.absolute_path(value) or value
end

local function path_suggestions(text)
  local expanded = common.home_expand(text)
  return common.home_encode_list(common.dir_path_suggest(expanded))
end

local function ask_path(label, default, submit)
  core.command_view:enter(label, {
    text = common.home_encode(default),
    select_text = true,
    submit = function(text, item) submit(normalize_input(text, item)) end,
    suggest = path_suggestions
  })
end

local function format_summary(info)
  local summary = string.format(
    "%d addon(s), %d settings file(s), %d color scheme(s), %d custom plugin(s), %d custom libraries",
    info.addon_count,
    info.file_count,
    info.color_count,
    info.custom_plugin_count,
    info.custom_library_count
  )
  local notices = {}
  if info.platform_differs or info.arch_differs then
    notices[#notices + 1] = string.format(
      "Source system: %s/%s; current system: %s/%s. Managed addons will be resolved locally by LPM.",
      info.source_platform, info.source_arch, info.current_platform, info.current_arch
    )
  end
  if info.excluded_component_count > 0 then
    notices[#notices + 1] = string.format(
      "%d custom component(s) containing native binaries were excluded during export.",
      info.excluded_component_count
    )
  end
  if info.absolute_path_reference_count > 0 then
    notices[#notices + 1] = string.format(
      "%d absolute path reference(s) require review on the destination system.",
      info.absolute_path_reference_count
    )
  end
  if info.native_component_count > 0 then
    notices[#notices + 1] = string.format(
      "%d custom component(s) containing native binaries are present and will be ignored.",
      info.native_component_count
    )
  end
  local installation = info.installation
  if installation and not installation.is_pristine then
    notices[#notices + 1] = string.format(
      "The current user directory is not empty: %d plugin(s), %d library/libraries, %d color scheme(s), %d settings file(s).",
      installation.plugin_count,
      installation.library_count,
      installation.color_count,
      installation.settings_count
    )
  end
  if #notices > 0 then summary = summary .. "\n\n" .. table.concat(notices, "\n") end
  return summary
end

local function show_error(message)
  core.error("Confexport: %s", tostring(message))
end

local function add_missing_repositories(repositories)
  if #repositories == 0 then return true end
  local output, err = run_lpm { "repo", "list" }
  if not output then return nil, err end
  local current
  current, err = decode_lpm(output, "repository listing")
  if not current then return nil, err end

  local existing = {}
  for _, repository in ipairs(current.repositories or {}) do
    existing[repository.remote .. ":" .. (repository.branch or "master")] = true
  end
  local missing = {}
  for _, repository in ipairs(repositories) do
    if type(repository.remote) == "string" then
      local value = repository.remote .. ":" .. (repository.branch or "master")
      if not existing[value] then missing[#missing + 1] = value end
    end
  end
  if #missing == 0 then return true end
  local arguments = { "repo", "add" }
  for _, repository in ipairs(missing) do arguments[#arguments + 1] = repository end
  output, err = run_lpm(arguments)
  if not output then return nil, err end
  return true
end

local function install_addons(manifest)
  if #manifest.addons == 0 then return true end
  local arguments = { "install", "--assume-yes" }
  for _, addon in ipairs(manifest.addons) do
    if type(addon.id) ~= "string" or not addon.id:match("^[%w_.%-]+$") then
      return nil, "invalid addon identifier in manifest"
    end
    local value = addon.id
    if addon.version ~= nil then value = value .. ":" .. tostring(addon.version) end
    arguments[#arguments + 1] = value
  end
  local output, err = run_lpm(arguments)
  if not output then return nil, err end
  return true
end

local function perform_import(path, install_managed_addons)
  core.add_thread(function()
    local info, err = profile.inspect(path)
    if not info then show_error(err) return end
    core.log("Confexport: importing %s", path)

    if install_managed_addons then
      local ok
      ok, err = add_missing_repositories(info.manifest.repositories)
      if not ok then
        core.nag_view:show(
          "LPM Could Not Restore Addons",
          "LPM is unavailable or the repository restore failed:\n" .. tostring(err)
            .. "\n\nContinue with local configuration files only? Managed addons can be installed later.",
          {
            { text = "Local Files Only", default_yes = true },
            { text = "Cancel", default_no = true }
          },
          function(item)
            if item.text == "Local Files Only" then perform_import(path, false) end
          end
        )
        return
      end
      ok, err = install_addons(info.manifest)
      if not ok then
        core.nag_view:show(
          "LPM Could Not Restore Addons",
          "LPM could not install the managed addons:\n" .. tostring(err)
            .. "\n\nContinue with local configuration files only? Managed addons can be installed later.",
          {
            { text = "Local Files Only", default_yes = true },
            { text = "Cancel", default_no = true }
          },
          function(item)
            if item.text == "Local Files Only" then perform_import(path, false) end
          end
        )
        return
      end
    end

    local result
    result, err = profile.apply(path, {
      create_backup = config.plugins.confexport.create_backup
    })
    if not result then show_error(err) return end

    local backup_message = result.backup_path and (" Backup: " .. result.backup_path) or ""
    if #result.skipped_native > 0 then
      core.warn(
        "Confexport: ignored %d custom component(s) containing native binaries.",
        #result.skipped_native
      )
    end
    core.log("Confexport: import complete.%s", backup_message)
    core.nag_view:show(
      "Confexport",
      "Configuration imported successfully." .. backup_message .. " Restart Lite XL now?",
      {
        { text = "Restart", default_yes = true },
        { text = "Later", default_no = true }
      },
      function(item)
        if item.text == "Restart" then command.perform("core:restart") end
      end
    )
  end)
end

local function confirm_import(path, install_managed_addons)
  local info, err = profile.inspect(path)
  if not info then show_error(err) return end
  local warning = install_managed_addons
    and "Managed addons will be installed before local files are replaced."
    or "This backup will replace matching local files."
  local backup_notice = config.plugins.confexport.create_backup
    and " A backup will be created first."
    or " Automatic backup is disabled."
  core.nag_view:show(
    "Import Lite XL Configuration",
    format_summary(info) .. "\n\n" .. warning
      .. backup_notice .. " Only import profiles you trust: they contain executable Lua code.",
    install_managed_addons and #info.manifest.addons > 0 and {
      { text = "Import + Addons", default_yes = true },
      { text = "Local Files Only" },
      { text = "Cancel", default_no = true }
    } or {
      { text = "Import", default_yes = true },
      { text = "Cancel", default_no = true }
    },
    function(item)
      if item.text == "Import" or item.text == "Import + Addons" then
        perform_import(path, install_managed_addons)
      elseif item.text == "Local Files Only" then
        perform_import(path, false)
      end
    end
  )
end

function confexport.export(path)
  core.add_thread(function()
    core.log("Confexport: collecting LPM inventory...")
    local inventory, err = load_inventory()
    if not inventory then show_error(err) return end
    local result
    result, err = profile.export(path, inventory, config.plugins.confexport)
    if not result then show_error(err) return end
    core.log(
      "Confexport: profile exported to %s (%d addons, %d color schemes, %d custom plugins, %d custom libraries)",
      result.path,
      #result.addons,
      #result.colors,
      #result.custom_plugins,
      #result.custom_libraries
    )
    if #result.excluded_components > 0 then
      core.warn(
        "Confexport: excluded %d custom component(s) containing native binaries; details are in manifest.json.",
        #result.excluded_components
      )
    end
    if #result.absolute_path_references > 0 then
      core.warn(
        "Confexport: found %d absolute path reference(s); review manifest.json before importing on another system.",
        #result.absolute_path_references
      )
    end
  end)
end

function confexport.import(path)
  confirm_import(path, true)
end

function confexport.preview(path)
  local info, err = profile.inspect(path)
  if not info then show_error(err) return end
  core.log("Confexport profile %s: %s", info.path, format_summary(info))
  core.root_view:open_doc(core.open_doc(info.path .. PATHSEP .. "manifest.json"))
end

local function ask_repository(submit)
  core.command_view:enter("Git Repository URL", {
    text = config.plugins.confexport.sync_repository or "",
    select_text = true,
    suggest = repository_suggestions,
    submit = function(text)
      text = trim(text)
      if text == "" then show_error("no synchronization repository was provided") return end
      config.plugins.confexport.sync_repository = text
      core.log(
        "Confexport: repository selected for this session. It will be added to recent repositories after a successful Git operation."
      )
      submit()
    end
  })
end

local function with_repository(callback)
  if type(config.plugins.confexport.sync_repository) ~= "string"
    or config.plugins.confexport.sync_repository:match("^%s*$")
  then
    core.add_thread(function()
      local repository = sync.local_repository(config.plugins.confexport, run_process)
      if repository then
        config.plugins.confexport.sync_repository = repository
        remember_repository(repository)
        core.log("Confexport: reusing the local Git origin %s.", repository)
        callback()
      else
        ask_repository(callback)
      end
    end)
  else
    callback()
  end
end

function confexport.sync_setup()
  with_repository(function()
    core.add_thread(function()
      core.log("Confexport: setting up Git synchronization...")
      local result, err = sync.setup(config.plugins.confexport, run_process)
      if not result then show_error(err) return end
      remember_repository(result.options.repository)
      core.log(
        "Confexport: synchronization repository ready at %s (%s).",
        result.options.directory,
        result.git_version
      )
    end)
  end)
end


function confexport.sync_status()
  core.add_thread(function()
    local result, err = sync.status(config.plugins.confexport, run_process)
    if not result then show_error(err) return end
    local remote_state = result.remote_head
      and string.format("ahead %d, behind %d", result.ahead, result.behind)
      or "remote branch not created"
    core.log(
      "Confexport sync: %s on %s; working tree %s; %s; profile %s.",
      result.remote or "no origin",
      result.branch ~= "" and result.branch or "unborn branch",
      result.clean and "clean" or "dirty",
      remote_state,
      result.profile_exists and "present" or "absent"
    )
    if not result.clean then core.warn("Confexport sync changes:\n%s", result.changes) end
  end)
end


function confexport.sync_pull()
  core.add_thread(function()
    core.log("Confexport: fetching synchronized configuration...")
    local result, err = sync.pull(config.plugins.confexport, run_process)
    if not result then show_error(err) return end
    if result.ahead > 0 then
      core.warn(
        "Confexport: the local sync repository is %d commit(s) ahead; these commits were not discarded.",
        result.ahead
      )
    end
    core.log(
      "Confexport: synchronized profile %s%s.",
      result.profile_path,
      result.updated and " was updated" or " is already current"
    )
    confirm_import(result.profile_path, true)
  end)
end


local function format_sync_changes(transaction)
  if #transaction.changes == 0 then return "No profile file changed." end
  local lines = {}
  local limit = math.min(#transaction.changes, 18)
  for index = 1, limit do
    local change = transaction.changes[index]
    lines[#lines + 1] = string.format("%s  %s", change.status, change.path)
  end
  if #transaction.changes > limit then
    lines[#lines + 1] = string.format("... and %d more file(s)", #transaction.changes - limit)
  end
  return table.concat(lines, "\n")
end


local function format_secret_findings(findings)
  local lines = {}
  local limit = math.min(#findings, 8)
  for index = 1, limit do
    local finding = findings[index]
    lines[#lines + 1] = string.format(
      "%s:%d — %s", finding.file, finding.line, finding.rule
    )
  end
  if #findings > limit then
    lines[#lines + 1] = string.format("... and %d more finding(s)", #findings - limit)
  end
  return table.concat(lines, "\n")
end


local function confirm_sync_push(transaction)
  local has_secrets = #transaction.secrets > 0
  local blocked = has_secrets and transaction.options.block_on_secrets
  local message = string.format(
    "Repository: %s\nBranch: %s\nProfile: %s\n\nProposed changes:\n%s",
    transaction.options.repository,
    transaction.options.branch,
    transaction.options.profile_relative,
    format_sync_changes(transaction)
  )
  if has_secrets then
    message = message .. "\n\nPossible secrets (values are never displayed):\n"
      .. format_secret_findings(transaction.secrets)
    if blocked then
      message = message
        .. "\n\nPush blocked. Remove the secrets, exclude the reviewed file, or disable the blocking option explicitly."
    else
      message = message .. "\n\nSecret blocking is disabled. Review these findings carefully."
    end
  end
  local push_label = #transaction.changes == 0 and "Push Pending Commits" or "Commit + Push"
  core.nag_view:show(
    "Synchronize Lite XL Configuration",
    message,
    blocked and {
      { text = "Cancel", default_no = true }
    } or {
      { text = push_label, default_yes = true },
      { text = "Cancel", default_no = true }
    },
    function(item)
      if not blocked and item and item.text == push_label then
        core.add_thread(function()
          local result, err = sync.commit_push(transaction, run_process)
          if not result then show_error(err) return end
          remember_repository(transaction.options.repository)
          if result.unchanged and not result.pushed then
            core.log("Confexport: synchronized profile is already up to date.")
          elseif result.unchanged then
            core.log("Confexport: pending Git commits pushed successfully.")
          else
            core.log("Confexport: configuration committed and pushed successfully.")
          end
        end)
      else
        local ok, err = sync.cancel_push(transaction)
        if not ok then show_error(err) end
      end
    end
  )
end


function confexport.sync_push()
  with_repository(function()
    core.add_thread(function()
      core.log("Confexport: preparing synchronized configuration export...")
      local inventory, err = load_inventory()
      if not inventory then show_error(err) return end
      local transaction
      transaction, err = sync.prepare_push(
        config.plugins.confexport,
        inventory,
        config.plugins.confexport,
        run_process
      )
      if not transaction then show_error(err) return end
      confirm_sync_push(transaction)
    end)
  end)
end

command.add(nil, {
  ["confexport:export"] = function()
    local base = config.plugins.confexport.export_directory
    local name = "lite-xl-profile-" .. os.date("%Y%m%d-%H%M%S")
    ask_path("Export Lite XL Configuration", base .. PATHSEP .. name, confexport.export)
  end,
  ["confexport:import"] = function()
    ask_path("Import Lite XL Configuration", config.plugins.confexport.export_directory, confexport.import)
  end,
  ["confexport:preview"] = function()
    ask_path("Preview Lite XL Configuration", config.plugins.confexport.export_directory, confexport.preview)
  end,
  ["confexport:restore-latest-backup"] = function()
    local latest = profile.latest_backup()
    if not latest then show_error("no backup found") return end
    confirm_import(latest, false)
  end,
  ["confexport:sync-setup"] = confexport.sync_setup,
  ["confexport:sync-status"] = confexport.sync_status,
  ["confexport:sync-pull"] = confexport.sync_pull,
  ["confexport:sync-push"] = confexport.sync_push
})

return confexport
