local M = {}

local async = require("plenary.async")
local git = require("gitlinker.git")
local buffer = require("gitlinker.buffer")
local mappings = require("gitlinker.mappings")
local opts = require("gitlinker.opts")
local path = require("plenary.path")

-- public
M.hosts = require("gitlinker.hosts")
M.actions = require("gitlinker.actions")

--- Setup the plugin configuration
--
-- Sets the options
-- Sets the hosts callbacks
-- Sets the mappings
--
-- @param config table with the schema
-- {
--   opts = {
--    remote = "<remotename>", -- force the use of a specific remote
--    add_current_line_on_normal_mode = true/false, -- add the line nr to the url
--    url_callback = <func> -- what to do with the url
--   }, -- check gitlinker/opts for the default values
--  callbacks = {
--    ["githostname.tld"] = <func> -- where <func> is a function that takes a
--    url_data table and returns the url
--   },
--  mappings = "<keys>"-- keys for normal and visual mode keymaps
-- }
-- @param user_opts a table to override options passed in M.setup()
function M.setup(config)
  if config then
    opts.setup(config.opts)
    M.hosts.callbacks =
      vim.tbl_deep_extend("force", M.hosts.callbacks, config.callbacks or {})
    mappings.set(config.mappings)
  else
    opts.setup()
    mappings.set()
  end
end

local function get_buf_range_url_data(mode, user_opts)
  local repo = git.get_repo()
  if not repo then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil
  end
  mode = mode or "n"
  local remote = git.get_branch_remote(repo) or user_opts.remote
  local repo_url_data = git.get_repo_data(remote, repo)
  if not repo_url_data then
    return nil
  end

  local rev = git.get_closest_remote_compatible_rev(remote, repo)
  if not rev then
    return nil
  end

  local buf_repo_path = buffer.get_relative_path(repo.root)
  if not git.is_file_in_rev(buf_repo_path, rev, repo) then
    vim.notify(
      string.format("'%s' does not exist in remote '%s'", buf_repo_path, remote),
      vim.log.levels.ERROR
    )
    return nil
  end

  if
    git.has_file_changed(buf_repo_path, rev, repo)
    and (mode == "v" or user_opts.add_current_line_on_normal_mode)
  then
    vim.notify(
      string.format(
        "Computed Line numbers are probably wrong because '%s' has changes",
        buf_repo_path
      ),
      vim.log.levels.WARN
    )
  end
  local range =
    buffer.get_range(mode, user_opts.add_current_line_on_normal_mode)

  return vim.tbl_extend("force", repo_url_data, {
    rev = rev,
    file = buf_repo_path,
    lstart = range.lstart,
    lend = range.lend,
  })
end

local function get_buf_range_url_data_async(mode, user_opts)
  mode = mode or "n"
  local buf_name = vim.api.nvim_buf_get_name(0)
  local range =
    buffer.get_range(mode, user_opts.add_current_line_on_normal_mode)

  local repo = git.get_repo_async()
  if not repo then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil
  end
  local remote = git.get_branch_remote_async(repo) or user_opts.remote
  local repo_url_data = git.get_repo_data_async(remote, repo)
  if not repo_url_data then
    return nil
  end

  local rev = git.get_closest_remote_compatible_rev_async(remote, repo)
  if not rev then
    return nil
  end

  local buf_repo_path = path:new(buf_name):make_relative(repo.root)
  if not git.is_file_in_rev_async(buf_repo_path, rev, repo) then
    vim.notify(
      string.format("'%s' does not exist in remote '%s'", buf_repo_path, remote),
      vim.log.levels.ERROR
    )
    return nil
  end

  if
    git.has_file_changed_async(buf_repo_path, rev, repo)
    and (mode == "v" or user_opts.add_current_line_on_normal_mode)
  then
    vim.notify(
      string.format(
        "Computed Line numbers are probably wrong because '%s' has changes",
        buf_repo_path
      ),
      vim.log.levels.WARN
    )
  end

  return vim.tbl_extend("force", repo_url_data, {
    rev = rev,
    file = buf_repo_path,
    lstart = range.lstart,
    lend = range.lend,
  })
end

local function handle_url(url, user_opts)
  if user_opts.action_callback then
    user_opts.action_callback(url)
  end
  if user_opts.print_url then
    vim.notify(url)
  end
end

--- Retrieves the url for the selected buffer range
--
-- Gets the url data elements
-- Passes it to the matching host callback
-- Retrieves the url from the host callback
-- Passes the url to the url callback
-- Prints the url
--
-- @param mode vim's mode this function was called on. Either 'v' or 'n'
-- @param user_opts a table to override options passed
--
-- @returns The url string
function M.get_buf_range_url_sync(mode, user_opts)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})

  local url_data = get_buf_range_url_data(mode, user_opts)
  if not url_data then
    return nil
  end

  local matching_callback = M.hosts.get_matching_callback(url_data.host)
  if not matching_callback then
    return nil
  end

  local url = matching_callback(url_data)

  handle_url(url, user_opts)

  return url
end

function M.get_buf_range_url_async(mode, user_opts, callback)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})

  async.run(function()
    local url_data = get_buf_range_url_data_async(mode, user_opts)
    if not url_data then
      return nil
    end

    local matching_callback = M.hosts.get_matching_callback(url_data.host)
    if not matching_callback then
      return nil
    end

    local url = matching_callback(url_data)
    handle_url(url, user_opts)
    return url
  end, callback)
end

function M.get_buf_range_url(mode, user_opts)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})
  if user_opts.async == false then
    return M.get_buf_range_url_sync(mode, user_opts)
  end

  M.get_buf_range_url_async(mode, user_opts)
  return nil
end

function M.get_repo_url_sync(user_opts)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})

  local repo = git.get_repo()
  if not repo then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil
  end

  local repo_url_data =
    git.get_repo_data(git.get_branch_remote(repo) or user_opts.remote, repo)
  if not repo_url_data then
    return nil
  end

  local matching_callback = M.hosts.get_matching_callback(repo_url_data.host)
  if not matching_callback then
    return nil
  end

  local url = matching_callback(repo_url_data)

  handle_url(url, user_opts)

  return url
end

function M.get_repo_url_async(user_opts, callback)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})

  async.run(function()
    local repo = git.get_repo_async()
    if not repo then
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return nil
    end

    local repo_url_data = git.get_repo_data_async(
      git.get_branch_remote_async(repo) or user_opts.remote,
      repo
    )
    if not repo_url_data then
      return nil
    end

    local matching_callback = M.hosts.get_matching_callback(repo_url_data.host)
    if not matching_callback then
      return nil
    end

    local url = matching_callback(repo_url_data)
    handle_url(url, user_opts)
    return url
  end, callback)
end

function M.get_repo_url(user_opts)
  user_opts = vim.tbl_deep_extend("force", opts.get(), user_opts or {})
  if user_opts.async == false then
    return M.get_repo_url_sync(user_opts)
  end

  M.get_repo_url_async(user_opts)
  return nil
end

return M
