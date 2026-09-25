local common = require "core.common"
local json = require "libraries.json"

local profile = {}

profile.VERSION = "0.4.0"
profile.SCHEMA = "org.lite-xl.confexport.profile"
profile.FORMAT_VERSION = 1

local function join(...)
  local parts = { ... }
  return table.concat(parts, PATHSEP)
end

local function normalize(path)
  return common.normalize_path(system.absolute_path(path) or path)
end

local module_source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_directory = common.dirname(module_source)

local function package_file(module_name)
  if package.searchpath then
    local path = package.searchpath(module_name, package.path)
    if path then return path end
  end
  local module_path = module_name:gsub("%.", PATHSEP)
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", module_path)
    if system.get_file_info(candidate) then return candidate end
  end
end

local function ensure_dir(path)
  local info = system.get_file_info(path)
  if info then
    if info.type ~= "dir" then
      return nil, "not a directory: " .. path
    end
    return true
  end
  local ok, err, failed_path = common.mkdirp(path)
  if not ok then
    return nil, string.format("%s: %s", err or "cannot create directory", failed_path or path)
  end
  return true
end

local function read_file(path)
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err end
  local data = fp:read("*a")
  fp:close()
  return data
end

local function write_file(path, data)
  local parent = common.dirname(path)
  if parent then
    local ok, err = ensure_dir(parent)
    if not ok then return nil, err end
  end
  local fp, err = io.open(path, "wb")
  if not fp then return nil, err end
  local ok, write_err = fp:write(data)
  fp:close()
  if not ok then return nil, write_err end
  return true
end

local function copy_file(source, target)
  local input, err = io.open(source, "rb")
  if not input then return nil, err end
  local parent = common.dirname(target)
  local ok
  ok, err = ensure_dir(parent)
  if not ok then
    input:close()
    return nil, err
  end
  local output
  output, err = io.open(target, "wb")
  if not output then
    input:close()
    return nil, err
  end
  while true do
    local chunk = input:read(1024 * 1024)
    if not chunk then break end
    local wrote, write_err = output:write(chunk)
    if not wrote then
      input:close()
      output:close()
      return nil, write_err
    end
  end
  input:close()
  output:close()
  return true
end

local function copy_tree(source, target)
  local info = system.get_file_info(source)
  if not info then return nil, "source does not exist: " .. source end
  if info.type == "file" then return copy_file(source, target) end
  if info.type ~= "dir" then return nil, "unsupported file type: " .. source end

  local ok, err = ensure_dir(target)
  if not ok then return nil, err end
  local entries = system.list_dir(source) or {}
  table.sort(entries)
  for _, name in ipairs(entries) do
    ok, err = copy_tree(join(source, name), join(target, name))
    if not ok then return nil, err end
  end
  return true
end

local native_extensions = {
  [".dll"] = true,
  [".dylib"] = true,
  [".exe"] = true,
  [".lib"] = true,
  [".a"] = true,
  [".o"] = true,
  [".obj"] = true
}

local native_magic = {
  ["\127ELF"] = "ELF binary",
  ["MZ"] = "Windows executable",
  ["\254\237\250\206"] = "Mach-O binary",
  ["\206\250\237\254"] = "Mach-O binary",
  ["\254\237\250\207"] = "Mach-O binary",
  ["\207\250\237\254"] = "Mach-O binary",
  ["\202\254\186\190"] = "Mach-O universal binary",
  ["\190\186\254\202"] = "Mach-O universal binary"
}

local function native_reason(path)
  local lower = path:lower()
  if lower:match("%.so(%.[%d.]+)?$") then return "native shared library" end
  for extension in pairs(native_extensions) do
    if lower:sub(-#extension) == extension then return "native binary (" .. extension .. ")" end
  end

  local fp = io.open(path, "rb")
  if not fp then return nil end
  local header = fp:read(4) or ""
  fp:close()
  for magic, reason in pairs(native_magic) do
    if header:sub(1, #magic) == magic then return reason end
  end
end

local function portable_join(parent, child)
  return parent == "" and child or (parent .. "/" .. child)
end

local function find_native_files(path, relative, result)
  result = result or {}
  local info = system.get_file_info(path)
  if not info then return result end
  if info.type == "file" then
    local reason = native_reason(path)
    if reason then result[#result + 1] = { path = relative, reason = reason } end
    return result
  end
  if info.type ~= "dir" then return result end
  local entries = system.list_dir(path) or {}
  table.sort(entries)
  for _, name in ipairs(entries) do
    find_native_files(join(path, name), portable_join(relative, name), result)
  end
  return result
end

local text_extensions = {
  [".lua"] = true,
  [".json"] = true,
  [".toml"] = true,
  [".yaml"] = true,
  [".yml"] = true
}

local function text_file_for_path_scan(path)
  local lower = path:lower()
  for extension in pairs(text_extensions) do
    if lower:sub(-#extension) == extension then return true end
  end
  return false
end

local function absolute_path_style(value)
  if value:match("^%a:[/\\]") or value:sub(1, 2) == "\\\\" then return "windows" end
  if value:sub(1, 1) == "/" then return "unix" end
end

local function scan_absolute_path_references(path, relative, result)
  result = result or {}
  local info = system.get_file_info(path)
  if not info then return result end
  if info.type == "dir" then
    local entries = system.list_dir(path) or {}
    table.sort(entries)
    for _, name in ipairs(entries) do
      scan_absolute_path_references(
        join(path, name), portable_join(relative, name), result
      )
    end
    return result
  end
  if info.type ~= "file" or not text_file_for_path_scan(path) then return result end

  local fp = io.open(path, "r")
  if not fp then return result end
  local line_number = 0
  for line in fp:lines() do
    line_number = line_number + 1
    if not line:match("^%s*%-%-") then
      local cursor = 1
      while cursor <= #line do
        local first, last, _, value = line:find("([\"'])(.-)%1", cursor)
        if not first then break end
        local concatenated_fragment = line:sub(1, first - 1):match("%.%.%s*$") ~= nil
        local path_style = not concatenated_fragment and absolute_path_style(value) or nil
        if path_style then
          result[#result + 1] = {
            file = relative,
            line = line_number,
            style = path_style
          }
          break
        end
        cursor = last + 1
      end
    end
  end
  fp:close()
  return result
end

local function remove_if_present(path)
  if not system.get_file_info(path) then return true end
  local ok, err, failed_path = common.rm(path, true)
  if not ok then
    return nil, string.format("%s: %s", err or "cannot remove path", failed_path or path)
  end
  return true
end

local function unique_path(base)
  if not system.get_file_info(base) then return base end
  local index = 2
  while system.get_file_info(base .. "-" .. index) do index = index + 1 end
  return base .. "-" .. index
end

local function managed_paths(addons)
  local paths = {}
  for _, addon in ipairs(addons or {}) do
    if (addon.status == "installed" or addon.status == "upgradable") and addon.path then
      paths[normalize(addon.path)] = true
    end
  end
  return paths
end

local function export_custom_entries(
  source_dir, target_dir, portable_root, known_paths,
  excluded_components, absolute_path_references
)
  local exported = {}
  local info = system.get_file_info(source_dir)
  if not info or info.type ~= "dir" then return exported end
  local entries = system.list_dir(source_dir) or {}
  table.sort(entries)
  for _, name in ipairs(entries) do
    local source = join(source_dir, name)
    if not known_paths[normalize(source)] then
      local portable_path = portable_join(portable_root, name)
      local native_files = find_native_files(source, portable_path)
      if #native_files > 0 then
        excluded_components[#excluded_components + 1] = {
          path = portable_path,
          reason = "contains native binaries",
          native_files = native_files
        }
      else
        local ok, err = copy_tree(source, join(target_dir, name))
        if not ok then return nil, err end
        scan_absolute_path_references(source, portable_path, absolute_path_references)
        exported[#exported + 1] = name
      end
    end
  end
  return exported
end

local function portable_repositories(repositories)
  local result = {}
  for _, repository in ipairs(repositories or {}) do
    if type(repository) == "table" and type(repository.remote) == "string" then
      result[#result + 1] = {
        remote = repository.remote,
        branch = repository.branch
      }
    end
  end
  table.sort(result, function(a, b)
    return (a.remote .. ":" .. (a.branch or "")) < (b.remote .. ":" .. (b.branch or ""))
  end)
  return result
end

local function portable_addons(addons)
  local result = {}
  for _, addon in ipairs(addons or {}) do
    if addon.status == "installed" or addon.status == "upgradable" then
      result[#result + 1] = {
        id = addon.id,
        type = addon.type,
        version = addon.version
      }
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

local function cleanup_failed_export(path)
  if system.get_file_info(path) then common.rm(path, true) end
end

local bootstrap_project = [[-- Generated by confexport. Opening this directory only registers an import command.
-- No file is changed and no network request is made until you explicitly confirm an import.
local core = require "core"
local command = require "core.command"

local root = system.absolute_path(".")
local function from_profile(relative)
  return root .. PATHSEP .. relative:gsub("/", PATHSEP)
end
local function load_profile_file(relative)
  local chunk, err = loadfile(from_profile(relative))
  if not chunk then error(err) end
  return chunk()
end

if not package.loaded["libraries.json"] then
  package.loaded["libraries.json"] = load_profile_file("bootstrap/json.lua")
end
package.loaded["plugins.confexport.profile"] =
  load_profile_file("custom-plugins/confexport/profile.lua")
package.loaded["plugins.confexport.sync"] =
  load_profile_file("custom-plugins/confexport/sync.lua")
package.loaded["plugins.confexport"] =
  load_profile_file("custom-plugins/confexport/init.lua")

command.add(nil, {
  ["confexport:bootstrap-import"] = function()
    package.loaded["plugins.confexport"].import(root)
  end
})
core.log("Confexport bootstrap ready. Run confexport:bootstrap-import to inspect and import this profile.")
]]

local function append_once(values, value)
  for _, current in ipairs(values) do
    if current == value then return end
  end
  values[#values + 1] = value
  table.sort(values)
end

local function add_bootstrap(staging, summary)
  local target_plugin = join(staging, "custom-plugins", "confexport")
  local ok, err
  if not system.get_file_info(target_plugin) then
    ok, err = copy_tree(plugin_directory, target_plugin)
    if not ok then return nil, err end
  end
  append_once(summary.custom_plugins, "confexport")

  local json_source = package_file("libraries.json")
  if not json_source then
    return nil, "cannot locate libraries/json.lua for the standalone bootstrap"
  end
  ok, err = copy_file(json_source, join(staging, "bootstrap", "json.lua"))
  if not ok then return nil, err end
  ok, err = write_file(join(staging, ".lite_project.lua"), bootstrap_project)
  if not ok then return nil, err end
  summary.bootstrap = true
  return true
end

function profile.export(target, inventory, options)
  options = options or {}
  target = normalize(target)
  if system.get_file_info(target) then
    return nil, "the export destination already exists: " .. target
  end

  local parent = common.dirname(target)
  local ok, err = ensure_dir(parent)
  if not ok then return nil, err end

  local staging = unique_path(target .. ".confexport-tmp")
  ok, err = ensure_dir(staging)
  if not ok then return nil, err end

  local summary = {
    files = {},
    colors = {},
    custom_plugins = {},
    custom_libraries = {},
    addons = portable_addons(inventory.addons),
    excluded_components = {},
    absolute_path_references = {}
  }

  local function fail(message)
    cleanup_failed_export(staging)
    return nil, message
  end

  for _, filename in ipairs { "init.lua", "user_settings.lua" } do
    local source = join(USERDIR, filename)
    if system.get_file_info(source) then
      ok, err = copy_file(source, join(staging, filename))
      if not ok then return fail(err) end
      scan_absolute_path_references(source, filename, summary.absolute_path_references)
      summary.files[#summary.files + 1] = filename
    end
  end

  local known_paths = managed_paths(inventory.addons)
  if options.include_colors ~= false then
    summary.colors, err = export_custom_entries(
      join(USERDIR, "colors"), join(staging, "colors"), "colors", known_paths,
      summary.excluded_components, summary.absolute_path_references
    )
    if not summary.colors then return fail(err) end
  end
  if options.include_custom_plugins ~= false then
    summary.custom_plugins, err = export_custom_entries(
      join(USERDIR, "plugins"), join(staging, "custom-plugins"), "custom-plugins", known_paths,
      summary.excluded_components, summary.absolute_path_references
    )
    if not summary.custom_plugins then return fail(err) end
  end
  if options.include_custom_libraries ~= false then
    summary.custom_libraries, err = export_custom_entries(
      join(USERDIR, "libraries"), join(staging, "custom-libraries"), "custom-libraries", known_paths,
      summary.excluded_components, summary.absolute_path_references
    )
    if not summary.custom_libraries then return fail(err) end
  end
  if options.include_bootstrap ~= false then
    ok, err = add_bootstrap(staging, summary)
    if not ok then return fail(err) end
  end

  local manifest = {
    schema = profile.SCHEMA,
    format_version = profile.FORMAT_VERSION,
    exporter_version = profile.VERSION,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    lite_xl = {
      version = tostring(rawget(_G, "VERSION") or "unknown"),
      mod_version = tostring(rawget(_G, "MOD_VERSION") or "unknown"),
      platform = tostring(rawget(_G, "PLATFORM") or "unknown"),
      arch = tostring(rawget(_G, "ARCH") or "unknown")
    },
    repositories = portable_repositories(inventory.repositories),
    addons = summary.addons,
    portability = {
      status = (#summary.excluded_components == 0 and #summary.absolute_path_references == 0)
        and "portable" or "review",
      excluded_components = summary.excluded_components,
      absolute_path_references = summary.absolute_path_references
    },
    content = {
      files = summary.files,
      colors = summary.colors,
      custom_plugins = summary.custom_plugins,
      custom_libraries = summary.custom_libraries,
      bootstrap = summary.bootstrap == true
    }
  }
  ok, err = write_file(join(staging, "manifest.json"), json.encode(manifest) .. "\n")
  if not ok then return fail(err) end

  local readme = [[This directory is a confexport profile for Lite XL.

Import it with the `confexport:import` command. If this profile contains the
optional bootstrap, open this directory in Lite XL and run
`confexport:bootstrap-import`. Managed addons are reinstalled by LPM for the
destination platform. Custom components containing native
binaries are excluded, and absolute paths are reported in manifest.json.
Lua files, color schemes, and custom plugins are executable code; only import
profiles from sources you trust.
]]
  ok, err = write_file(join(staging, "README.txt"), readme)
  if not ok then return fail(err) end

  local renamed, rename_err = os.rename(staging, target)
  if not renamed then return fail(rename_err or "cannot finalize export") end
  summary.path = target
  summary.manifest = manifest
  return summary
end

function profile.read(path)
  path = normalize(path)
  local data, err = read_file(join(path, "manifest.json"))
  if not data then return nil, "cannot read manifest.json: " .. tostring(err) end
  local ok, manifest = pcall(json.decode, data)
  if not ok then return nil, "invalid manifest.json: " .. tostring(manifest) end
  if type(manifest) ~= "table" or manifest.schema ~= profile.SCHEMA then
    return nil, "this directory is not a confexport profile"
  end
  if manifest.format_version ~= profile.FORMAT_VERSION then
    return nil, string.format(
      "unsupported profile format %s (expected %s)",
      tostring(manifest.format_version), profile.FORMAT_VERSION
    )
  end
  manifest.addons = type(manifest.addons) == "table" and manifest.addons or {}
  manifest.repositories = type(manifest.repositories) == "table" and manifest.repositories or {}
  return manifest, path
end

local function native_components_in_profile(root)
  local result = {}
  for _, directory in ipairs { "colors", "custom-plugins", "custom-libraries" } do
    local directory_path = join(root, directory)
    local info = system.get_file_info(directory_path)
    if info and info.type == "dir" then
      local entries = system.list_dir(directory_path) or {}
      table.sort(entries)
      for _, name in ipairs(entries) do
        local portable_path = portable_join(directory, name)
        local native_files = find_native_files(
          join(directory_path, name), portable_path
        )
        if #native_files > 0 then
          result[#result + 1] = {
            path = portable_path,
            reason = "contains native binaries",
            native_files = native_files
          }
        end
      end
    end
  end
  return result
end

local function count_user_entries(directory, ignored_name)
  local info = system.get_file_info(directory)
  if not info or info.type ~= "dir" then return 0 end
  local count = 0
  for _, name in ipairs(system.list_dir(directory) or {}) do
    if name ~= ignored_name then count = count + 1 end
  end
  return count
end

function profile.current_installation()
  local state = {
    plugin_count = count_user_entries(join(USERDIR, "plugins"), "confexport"),
    library_count = count_user_entries(join(USERDIR, "libraries")),
    color_count = count_user_entries(join(USERDIR, "colors")),
    settings_count = system.get_file_info(join(USERDIR, "user_settings.lua")) and 1 or 0
  }
  state.component_count = state.plugin_count + state.library_count + state.color_count
    + state.settings_count
  state.is_pristine = state.component_count == 0
  return state
end

function profile.inspect(path)
  local manifest, normalized_or_error = profile.read(path)
  if not manifest then return nil, normalized_or_error end
  local root = normalized_or_error
  local function count_entries(directory)
    local info = system.get_file_info(directory)
    return info and info.type == "dir" and #(system.list_dir(directory) or {}) or 0
  end
  local file_count = 0
  for _, filename in ipairs { "init.lua", "user_settings.lua" } do
    if system.get_file_info(join(root, filename)) then file_count = file_count + 1 end
  end
  local portability = type(manifest.portability) == "table" and manifest.portability or {}
  local excluded_components = type(portability.excluded_components) == "table"
    and portability.excluded_components or {}
  local absolute_path_references = type(portability.absolute_path_references) == "table"
    and portability.absolute_path_references or {}
  local native_components = manifest.backup and {} or native_components_in_profile(root)
  local source = type(manifest.lite_xl) == "table" and manifest.lite_xl or {}
  local current_platform = tostring(rawget(_G, "PLATFORM") or "unknown")
  local current_arch = tostring(rawget(_G, "ARCH") or "unknown")
  local source_platform = tostring(source.platform or "unknown")
  local source_arch = tostring(source.arch or "unknown")
  return {
    path = root,
    manifest = manifest,
    addon_count = #manifest.addons,
    file_count = file_count,
    color_count = count_entries(join(root, "colors")),
    custom_plugin_count = count_entries(join(root, "custom-plugins")),
    custom_library_count = count_entries(join(root, "custom-libraries")),
    excluded_component_count = #excluded_components,
    absolute_path_reference_count = #absolute_path_references,
    native_component_count = #native_components,
    source_platform = source_platform,
    source_arch = source_arch,
    current_platform = current_platform,
    current_arch = current_arch,
    platform_differs = source_platform ~= "unknown" and current_platform ~= "unknown"
      and source_platform ~= current_platform,
    arch_differs = source_arch ~= "unknown" and current_arch ~= "unknown"
      and source_arch ~= current_arch,
    installation = profile.current_installation()
  }
end

local mappings = {
  { profile_name = "colors", user_name = "colors" },
  { profile_name = "custom-plugins", user_name = "plugins" },
  { profile_name = "custom-libraries", user_name = "libraries" }
}

local function copy_profile_content(source_root, target_root, backup_root, allow_native)
  local copied = {}
  local introduced = {}
  local skipped_native = {}
  local function replace(source, target, backup, display_name)
    local target_exists = system.get_file_info(target) ~= nil
    if backup and target_exists then
      local ok, err = copy_tree(target, backup)
      if not ok then return nil, err end
    end

    local temporary = target .. ".confexport-import"
    local ok, err = remove_if_present(temporary)
    if not ok then return nil, err end
    ok, err = copy_tree(source, temporary)
    if not ok then
      remove_if_present(temporary)
      return nil, err
    end
    ok, err = remove_if_present(target)
    if not ok then
      remove_if_present(temporary)
      return nil, err
    end
    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then
      remove_if_present(temporary)
      return nil, rename_err or ("cannot replace " .. target)
    end
    if not target_exists then introduced[#introduced + 1] = display_name end
    copied[#copied + 1] = display_name
    return true
  end

  for _, filename in ipairs { "init.lua", "user_settings.lua" } do
    local source = join(source_root, filename)
    if system.get_file_info(source) then
      local backup = backup_root and join(backup_root, filename) or nil
      local ok, err = replace(source, join(target_root, filename), backup, filename)
      if not ok then return nil, err end
    end
  end

  for _, mapping in ipairs(mappings) do
    local source_dir = join(source_root, mapping.profile_name)
    local info = system.get_file_info(source_dir)
    if info and info.type == "dir" then
      local entries = system.list_dir(source_dir) or {}
      table.sort(entries)
      for _, name in ipairs(entries) do
        local source = join(source_dir, name)
        local portable_name = portable_join(mapping.profile_name, name)
        local native_files = allow_native and {} or find_native_files(source, portable_name)
        if #native_files > 0 then
          skipped_native[#skipped_native + 1] = {
            path = portable_name,
            reason = "contains native binaries",
            native_files = native_files
          }
        else
          local backup = backup_root and join(backup_root, mapping.profile_name, name) or nil
          local ok, err = replace(
            source,
            join(target_root, mapping.user_name, name),
            backup,
            portable_name
          )
          if not ok then return nil, err end
        end
      end
    end
  end
  return copied, introduced, skipped_native
end

local function target_from_profile_name(root, relative_name)
  if relative_name == "init.lua" or relative_name == "user_settings.lua" then
    return join(root, relative_name), relative_name
  end
  for _, mapping in ipairs(mappings) do
    local prefix = mapping.profile_name .. PATHSEP
    if relative_name:sub(1, #prefix) == prefix then
      local name = relative_name:sub(#prefix + 1)
      if name ~= "" and name ~= "." and name ~= ".."
        and not name:find("/", 1, true) and not name:find("\\", 1, true)
      then
        return join(root, mapping.user_name, name), join(mapping.profile_name, name)
      end
    end
  end
end

function profile.apply(path, options)
  options = options or {}
  local manifest, normalized_or_error = profile.read(path)
  if not manifest then return nil, normalized_or_error end
  local source_root = normalized_or_error
  local backup_root
  local err

  if options.create_backup ~= false then
    local backups_dir = join(USERDIR, "backups")
    local ok
    ok, err = ensure_dir(backups_dir)
    if not ok then return nil, err end
    backup_root = unique_path(join(backups_dir, "confexport-" .. os.date("%Y%m%d-%H%M%S")))
    ok, err = ensure_dir(backup_root)
    if not ok then return nil, err end
  end

  local remove_on_restore = {}
  if manifest.backup and type(manifest.remove_on_restore) == "table" then
    for _, relative_name in ipairs(manifest.remove_on_restore) do
      if type(relative_name) ~= "string" then
        return nil, "invalid backup removal entry"
      end
      local target, portable_name = target_from_profile_name(USERDIR, relative_name)
      if not target then return nil, "unsafe backup removal entry: " .. relative_name end
      if system.get_file_info(target) then
        if backup_root then
          local ok
          ok, err = copy_tree(target, join(backup_root, portable_name))
          if not ok then return nil, err end
        end
        local ok
        ok, err = remove_if_present(target)
        if not ok then return nil, err end
      end
    end
  end

  local copied, introduced_or_error, skipped_native = copy_profile_content(
    source_root, USERDIR, backup_root, manifest.backup == true
  )
  if not copied then return nil, introduced_or_error end
  local introduced = introduced_or_error

  if backup_root then
    local backup_manifest = {
      schema = profile.SCHEMA,
      format_version = profile.FORMAT_VERSION,
      exporter_version = profile.VERSION,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      backup = true,
      lite_xl = {
        version = tostring(rawget(_G, "VERSION") or "unknown"),
        mod_version = tostring(rawget(_G, "MOD_VERSION") or "unknown"),
        platform = tostring(rawget(_G, "PLATFORM") or "unknown"),
        arch = tostring(rawget(_G, "ARCH") or "unknown")
      },
      repositories = {},
      addons = {},
      portability = { status = "local-backup" },
      content = {},
      remove_on_restore = introduced
    }
    local ok
    ok, err = write_file(join(backup_root, "manifest.json"), json.encode(backup_manifest) .. "\n")
    if not ok then return nil, err end
  end

  return {
    path = source_root,
    backup_path = backup_root,
    copied = copied,
    skipped_native = skipped_native,
    manifest = manifest
  }
end

function profile.latest_backup()
  local backups_dir = join(USERDIR, "backups")
  local info = system.get_file_info(backups_dir)
  if not info or info.type ~= "dir" then return nil end
  local matches = {}
  for _, name in ipairs(system.list_dir(backups_dir) or {}) do
    if name:match("^confexport%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") then
      matches[#matches + 1] = name
    end
  end
  table.sort(matches)
  return matches[#matches] and join(backups_dir, matches[#matches]) or nil
end

return profile
