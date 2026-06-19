local M = {}

local async = require("plenary.async")
local job = require("plenary.job")
local path = require("plenary.path")

local function command(cmd, args, cwd)
  local p = job:new({
    command = cmd,
    args = args,
    cwd = cwd,
  })
  local output, code = p:sync()
  return output or {}, code
end

local command_async = async.wrap(function(cmd, args, cwd, callback)
  job
    :new({
      command = cmd,
      args = args,
      cwd = cwd,
    })
    :after(function(j, code)
      vim.schedule(function()
        callback(j:result() or {}, code)
      end)
    end)
    :start()
end, 4)

local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return vim.fn.getcwd()
  end
  return tostring(path:new(name):parent())
end

local repo_context_cache = {}

local function get_repo_context()
  local dir = buffer_dir()
  local cached = repo_context_cache[dir]
  if cached then
    return cached
  end

  local output, code = command("jj", { "root" }, dir)
  local jj_context
  if code == 0 and output[1] then
    local root = output[1]
    local _, log_code = command(
      "jj",
      { "log", "--no-graph", "--revisions", "@", "--template", "commit_id" },
      root
    )
    if log_code == 0 then
      jj_context = { vcs = "jj", root = root }
    end
  end

  output, code = command("git", { "rev-parse", "--show-toplevel" }, dir)
  if code == 0 and output[1] then
    local git_root = output[1]
    local context = { vcs = "git", root = git_root }
    if jj_context and #jj_context.root >= #git_root then
      context = jj_context
    end
    repo_context_cache[dir] = context
    return context
  end

  if jj_context then
    repo_context_cache[dir] = jj_context
    return jj_context
  end

  return nil
end

local function get_repo_context_async()
  local dir = buffer_dir()
  local cached = repo_context_cache[dir]
  if cached then
    return cached
  end

  local output, code = command_async("jj", { "root" }, dir)
  local jj_context
  if code == 0 and output[1] then
    local root = output[1]
    local _, log_code = command_async(
      "jj",
      { "log", "--no-graph", "--revisions", "@", "--template", "commit_id" },
      root
    )
    if log_code == 0 then
      jj_context = { vcs = "jj", root = root }
    end
  end

  output, code = command_async("git", { "rev-parse", "--show-toplevel" }, dir)
  if code == 0 and output[1] then
    local git_root = output[1]
    local context = { vcs = "git", root = git_root }
    if jj_context and #jj_context.root >= #git_root then
      context = jj_context
    end
    repo_context_cache[dir] = context
    return context
  end

  if jj_context then
    repo_context_cache[dir] = jj_context
    return jj_context
  end

  return nil
end

-- wrap the git command to do the right thing always
local function git(args, cwd)
  local context = get_repo_context()
  return command("git", args, cwd or (context and context.root))
end

local function jj(args, cwd)
  local context = get_repo_context()
  return command("jj", args, cwd or (context and context.root))
end

local function git_async(args, cwd)
  local context = get_repo_context_async()
  return command_async("git", args, cwd or (context and context.root))
end

local function jj_async(args, cwd)
  local context = get_repo_context_async()
  return command_async("jj", args, cwd or (context and context.root))
end

local function get_git_remotes(context)
  return git({ "remote" }, context and context.root)
end

local function get_git_remotes_async(context)
  return git_async({ "remote" }, context and context.root)
end

local function get_git_remote_uri(remote, context)
  assert(remote, "remote cannot be nil")
  return git({ "remote", "get-url", remote }, context and context.root)[1]
end

local function get_git_remote_uri_async(remote, context)
  assert(remote, "remote cannot be nil")
  return git_async({ "remote", "get-url", remote }, context and context.root)[1]
end

local function get_git_rev(revspec, context)
  return git({ "rev-parse", revspec }, context and context.root)[1]
end

local function get_git_rev_async(revspec, context)
  return git_async({ "rev-parse", revspec }, context and context.root)[1]
end

local function get_git_rev_name(revspec, context)
  return git({ "rev-parse", "--abbrev-ref", revspec }, context and context.root)[1]
end

local function get_git_rev_name_async(revspec, context)
  return git_async(
    { "rev-parse", "--abbrev-ref", revspec },
    context and context.root
  )[1]
end

local function get_git_root(context)
  if context then
    return context.root
  end
  context = get_repo_context()
  return context and context.root
end

local function is_jj_repo(context)
  context = context or get_repo_context()
  return context ~= nil and context.vcs == "jj"
end

local function get_jj_remotes(context)
  if context and context.remotes then
    return context.remotes
  end

  local output, code = jj({ "git", "remote", "list" }, context and context.root)
  if code ~= 0 then
    return {}
  end

  local remotes = {}
  local remote_uris = {}
  for _, line in ipairs(output) do
    local remote, uri = line:match("^(%S+)%s+(.+)$")
    if remote then
      remotes[#remotes + 1] = remote
      remote_uris[remote] = uri
    end
  end
  if context then
    context.remotes = remotes
    context.remote_uris = remote_uris
  end
  return remotes
end

local function get_jj_remotes_async(context)
  if context and context.remotes then
    return context.remotes
  end

  local output, code =
    jj_async({ "git", "remote", "list" }, context and context.root)
  if code ~= 0 then
    return {}
  end

  local remotes = {}
  local remote_uris = {}
  for _, line in ipairs(output) do
    local remote, uri = line:match("^(%S+)%s+(.+)$")
    if remote then
      remotes[#remotes + 1] = remote
      remote_uris[remote] = uri
    end
  end
  if context then
    context.remotes = remotes
    context.remote_uris = remote_uris
  end
  return remotes
end

local function get_jj_remote_uri(remote, context)
  assert(remote, "remote cannot be nil")
  get_jj_remotes(context)
  if context and context.remote_uris then
    return context.remote_uris[remote]
  end
  return nil
end

local function get_jj_remote_uri_async(remote, context)
  assert(remote, "remote cannot be nil")
  get_jj_remotes_async(context)
  if context and context.remote_uris then
    return context.remote_uris[remote]
  end
  return nil
end

local function jj_quote(str)
  return '"' .. str:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function get_jj_rev(revset, context)
  local output, code = jj({
    "log",
    "--no-graph",
    "--revisions",
    revset,
    "--template",
    'commit_id ++ "\n"',
  }, context and context.root)
  if code ~= 0 then
    return nil
  end
  return output[1]
end

local function get_jj_rev_async(revset, context)
  local output, code = jj_async({
    "log",
    "--no-graph",
    "--revisions",
    revset,
    "--template",
    'commit_id ++ "\n"',
  }, context and context.root)
  if code ~= 0 then
    return nil
  end
  return output[1]
end

local function is_git_file_in_rev(file, revspec, context)
  local _, code =
    git({ "cat-file", "-e", revspec .. ":" .. file }, context and context.root)
  if code == 0 then
    return true
  end
  return false
end

local function is_git_file_in_rev_async(file, revspec, context)
  local _, code = git_async(
    { "cat-file", "-e", revspec .. ":" .. file },
    context and context.root
  )
  if code == 0 then
    return true
  end
  return false
end

local function is_jj_file_in_rev(file, revspec, context)
  local output, code = jj(
    { "file", "list", "--revision", revspec, "--", file },
    context and context.root
  )
  if code ~= 0 then
    return false
  end
  for _, listed_file in ipairs(output) do
    if listed_file == file then
      return true
    end
  end
  return false
end

local function is_jj_file_in_rev_async(file, revspec, context)
  local output, code = jj_async(
    { "file", "list", "--revision", revspec, "--", file },
    context and context.root
  )
  if code ~= 0 then
    return false
  end
  for _, listed_file in ipairs(output) do
    if listed_file == file then
      return true
    end
  end
  return false
end

function M.is_file_in_rev(file, revspec, context)
  if is_jj_repo(context) then
    return is_jj_file_in_rev(file, revspec, context)
  end

  if is_git_file_in_rev(file, revspec, context) then
    return true
  end
  return false
end

function M.is_file_in_rev_async(file, revspec, context)
  if is_jj_repo(context) then
    return is_jj_file_in_rev_async(file, revspec, context)
  end

  if is_git_file_in_rev_async(file, revspec, context) then
    return true
  end
  return false
end

local function has_git_file_changed(file, rev, context)
  if git({ "diff", rev, "--", file }, context and context.root)[1] then
    return true
  end
  return false
end

local function has_git_file_changed_async(file, rev, context)
  if git_async({ "diff", rev, "--", file }, context and context.root)[1] then
    return true
  end
  return false
end

local function has_jj_file_changed(file, rev, context)
  return jj(
    { "diff", "--from", rev, "--to", "@", "--name-only", "--", file },
    context and context.root
  )[1] ~= nil
end

local function has_jj_file_changed_async(file, rev, context)
  return jj_async(
    { "diff", "--from", rev, "--to", "@", "--name-only", "--", file },
    context and context.root
  )[1] ~= nil
end

function M.has_file_changed(file, rev, context)
  if is_jj_repo(context) then
    return has_jj_file_changed(file, rev, context)
  end

  return has_git_file_changed(file, rev, context)
end

function M.has_file_changed_async(file, rev, context)
  if is_jj_repo(context) then
    return has_jj_file_changed_async(file, rev, context)
  end

  return has_git_file_changed_async(file, rev, context)
end

local function is_git_rev_in_remote(revspec, remote, context)
  assert(remote, "remote cannot be nil")
  local output = git(
    { "branch", "--remotes", "--contains", revspec },
    context and context.root
  )
  for _, rbranch in ipairs(output) do
    if rbranch:match(remote) then
      return true
    end
  end
  return false
end

local function is_git_rev_in_remote_async(revspec, remote, context)
  assert(remote, "remote cannot be nil")
  local output = git_async(
    { "branch", "--remotes", "--contains", revspec },
    context and context.root
  )
  for _, rbranch in ipairs(output) do
    if rbranch:match(remote) then
      return true
    end
  end
  return false
end

local allowed_chars = "[_%-%w%.]+"

-- strips the protocol (https://, git@, ssh://, etc)
local function strip_protocol(uri, errs)
  local protocol_schema = allowed_chars .. "://"
  local ssh_schema = allowed_chars .. "@"

  local stripped_uri = uri:match(protocol_schema .. "(.+)$")
    or uri:match(ssh_schema .. "(.+)$")
  if not stripped_uri then
    table.insert(
      errs,
      string.format(
        ": remote uri '%s' uses an unsupported protocol format",
        uri
      )
    )
    return nil
  end
  return stripped_uri
end

local function strip_dot_git(uri)
  return uri:match("(.+)%.git$") or uri
end

local function strip_uri(uri, errs)
  local stripped_uri = strip_protocol(uri, errs)
  return strip_dot_git(stripped_uri)
end

local function parse_host(stripped_uri, errs)
  local host_capture = "(" .. allowed_chars .. ")[:/].+$"
  local host = stripped_uri:match(host_capture)
  if not host then
    table.insert(
      errs,
      string.format(": cannot parse the hostname from uri '%s'", stripped_uri)
    )
  end
  return host
end

local function parse_port(stripped_uri, host)
  assert(host)
  local port_capture = allowed_chars .. ":([0-9]+)[:/].+$"
  return stripped_uri:match(port_capture)
end

local function parse_repo_path(stripped_uri, host, port, errs)
  assert(host)

  local pathChars = "[~/_%-%w%.%s]+"
  -- base of path capture
  local path_capture = "[:/](" .. pathChars .. ")$"

  -- if port is specified, add it to the path capture
  if port then
    path_capture = ":" .. port .. path_capture
  end

  -- add parsed host to path capture
  path_capture = allowed_chars .. path_capture

  -- parse repo path
  local repo_path = stripped_uri
    :gsub("%%20", " ") -- decode the space character
    :match(path_capture)
    :gsub(" ", "%%20") -- encode the space character
  if not repo_path then
    table.insert(
      errs,
      string.format(": cannot parse the repo path from uri '%s'", stripped_uri)
    )
    return nil
  end
  return repo_path
end

local function parse_uri(uri, errs)
  local stripped_uri = strip_uri(uri, errs)

  local host = parse_host(stripped_uri, errs)
  if not host then
    return nil
  end

  local port = parse_port(stripped_uri, host)

  local repo_path = parse_repo_path(stripped_uri, host, port, errs)
  if not repo_path then
    return nil
  end

  -- do not pass the port if it's NOT a http(s) uri since most likely the port
  -- is just an ssh port, so it's irrelevant to the git permalink construction
  -- (which is always an http url)
  if not uri:match("https?://") then
    port = nil
  end

  return { host = host, port = port, repo = repo_path }
end

local function get_git_closest_remote_compatible_rev(remote, context)
  -- try upstream branch HEAD (a.k.a @{u})
  local upstream_rev = get_git_rev("@{u}", context)
  if upstream_rev then
    return upstream_rev
  end

  -- try HEAD
  if is_git_rev_in_remote("HEAD", remote, context) then
    local head_rev = get_git_rev("HEAD", context)
    if head_rev then
      return head_rev
    end
  end

  -- try last 50 parent commits
  for i = 1, 50 do
    local revspec = "HEAD~" .. i
    if is_git_rev_in_remote(revspec, remote, context) then
      local rev = get_git_rev(revspec, context)
      if rev then
        return rev
      end
    end
  end

  -- try remote HEAD
  local remote_rev = get_git_rev(remote, context)
  if remote_rev then
    return remote_rev
  end

  vim.notify(
    string.format(
      "Failed to get closest revision in that exists in remote '%s'",
      remote
    ),
    vim.log.levels.ERROR
  )
  return nil
end

local function get_git_closest_remote_compatible_rev_async(remote, context)
  -- try upstream branch HEAD (a.k.a @{u})
  local upstream_rev = get_git_rev_async("@{u}", context)
  if upstream_rev then
    return upstream_rev
  end

  -- try HEAD
  if is_git_rev_in_remote_async("HEAD", remote, context) then
    local head_rev = get_git_rev_async("HEAD", context)
    if head_rev then
      return head_rev
    end
  end

  -- try last 50 parent commits
  for i = 1, 50 do
    local revspec = "HEAD~" .. i
    if is_git_rev_in_remote_async(revspec, remote, context) then
      local rev = get_git_rev_async(revspec, context)
      if rev then
        return rev
      end
    end
  end

  -- try remote HEAD
  local remote_rev = get_git_rev_async(remote, context)
  if remote_rev then
    return remote_rev
  end

  vim.notify(
    string.format(
      "Failed to get closest revision in that exists in remote '%s'",
      remote
    ),
    vim.log.levels.ERROR
  )
  return nil
end

local function get_jj_closest_remote_compatible_rev(remote, context)
  local remote_bookmarks = "remote_bookmarks(remote=" .. jj_quote(remote) .. ")"
  local ancestor =
    get_jj_rev("latest(heads(::@ & " .. remote_bookmarks .. "), 1)", context)
  if ancestor then
    return ancestor
  end

  local remote_rev =
    get_jj_rev("latest(" .. remote_bookmarks .. ", 1)", context)
  if remote_rev then
    return remote_rev
  end

  vim.notify(
    string.format(
      "Failed to get closest revision in that exists in remote '%s'",
      remote
    ),
    vim.log.levels.ERROR
  )
  return nil
end

local function get_jj_closest_remote_compatible_rev_async(remote, context)
  local remote_bookmarks = "remote_bookmarks(remote=" .. jj_quote(remote) .. ")"
  local ancestor = get_jj_rev_async(
    "latest(heads(::@ & " .. remote_bookmarks .. "), 1)",
    context
  )
  if ancestor then
    return ancestor
  end

  local remote_rev =
    get_jj_rev_async("latest(" .. remote_bookmarks .. ", 1)", context)
  if remote_rev then
    return remote_rev
  end

  vim.notify(
    string.format(
      "Failed to get closest revision in that exists in remote '%s'",
      remote
    ),
    vim.log.levels.ERROR
  )
  return nil
end

function M.get_closest_remote_compatible_rev(remote, context)
  if is_jj_repo(context) then
    return get_jj_closest_remote_compatible_rev(remote, context)
  end

  return get_git_closest_remote_compatible_rev(remote, context)
end

function M.get_closest_remote_compatible_rev_async(remote, context)
  if is_jj_repo(context) then
    return get_jj_closest_remote_compatible_rev_async(remote, context)
  end

  return get_git_closest_remote_compatible_rev_async(remote, context)
end

function M.get_repo_data(remote, context)
  local errs = {
    string.format("Failed to retrieve repo data for remote '%s'", remote),
  }
  local remote_uri
  if is_jj_repo(context) then
    remote_uri = get_jj_remote_uri(remote, context)
  else
    remote_uri = get_git_remote_uri(remote, context)
  end
  if not remote_uri then
    table.insert(
      errs,
      string.format(": cannot retrieve url from remote '%s'", remote)
    )
    return nil
  end

  local repo = parse_uri(remote_uri, errs)
  if not repo or vim.tbl_isempty(repo) then
    vim.notify(table.concat(errs), vim.log.levels.ERROR)
  end
  return repo
end

function M.get_repo_data_async(remote, context)
  local errs = {
    string.format("Failed to retrieve repo data for remote '%s'", remote),
  }
  local remote_uri
  if is_jj_repo(context) then
    remote_uri = get_jj_remote_uri_async(remote, context)
  else
    remote_uri = get_git_remote_uri_async(remote, context)
  end
  if not remote_uri then
    table.insert(
      errs,
      string.format(": cannot retrieve url from remote '%s'", remote)
    )
    return nil
  end

  local repo = parse_uri(remote_uri, errs)
  if not repo or vim.tbl_isempty(repo) then
    vim.notify(table.concat(errs), vim.log.levels.ERROR)
  end
  return repo
end

function M.get_git_root()
  return get_git_root()
end

local function get_git_branch_remote(context)
  local remotes = get_git_remotes(context)
  if #remotes == 0 then
    vim.notify("Git repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  local upstream_branch = get_git_rev_name("@{u}", context)
  if not upstream_branch then
    return nil
  end

  local remote_from_upstream_branch =
    upstream_branch:match("^(" .. allowed_chars .. ")%/")
  if not remote_from_upstream_branch then
    error(
      string.format(
        "Could not parse remote name from remote branch '%s'",
        upstream_branch
      )
    )
    return nil
  end
  for _, remote in ipairs(remotes) do
    if remote_from_upstream_branch == remote then
      return remote
    end
  end

  error(
    string.format(
      "Parsed remote '%s' from remote branch '%s' is not a valid remote",
      remote_from_upstream_branch,
      upstream_branch
    )
  )
  return nil
end

local function get_git_branch_remote_async(context)
  local remotes = get_git_remotes_async(context)
  if #remotes == 0 then
    vim.notify("Git repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  local upstream_branch = get_git_rev_name_async("@{u}", context)
  if not upstream_branch then
    return nil
  end

  local remote_from_upstream_branch =
    upstream_branch:match("^(" .. allowed_chars .. ")%/")
  if not remote_from_upstream_branch then
    error(
      string.format(
        "Could not parse remote name from remote branch '%s'",
        upstream_branch
      )
    )
    return nil
  end
  for _, remote in ipairs(remotes) do
    if remote_from_upstream_branch == remote then
      return remote
    end
  end

  error(
    string.format(
      "Parsed remote '%s' from remote branch '%s' is not a valid remote",
      remote_from_upstream_branch,
      upstream_branch
    )
  )
  return nil
end

local function get_jj_branch_remote(context)
  local remotes = get_jj_remotes(context)
  if #remotes == 0 then
    vim.notify("JJ repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  return nil
end

local function get_jj_branch_remote_async(context)
  local remotes = get_jj_remotes_async(context)
  if #remotes == 0 then
    vim.notify("JJ repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  return nil
end

function M.get_branch_remote(context)
  if is_jj_repo(context) then
    return get_jj_branch_remote(context)
  end

  return get_git_branch_remote(context)
end

function M.get_branch_remote_async(context)
  if is_jj_repo(context) then
    return get_jj_branch_remote_async(context)
  end

  return get_git_branch_remote_async(context)
end

function M.get_repo()
  return get_repo_context()
end

function M.get_repo_async()
  return get_repo_context_async()
end

return M
