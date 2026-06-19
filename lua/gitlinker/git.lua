local M = {}

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

local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return vim.fn.getcwd()
  end
  return tostring(path:new(name):parent())
end

-- wrap the git command to do the right thing always
local function git(args, cwd)
  return command("git", args, cwd or M.get_git_root())
end

local function jj(args, cwd)
  return command("jj", args, cwd or M.get_git_root())
end

local function get_git_remotes()
  return git({ "remote" })
end

local function get_git_remote_uri(remote)
  assert(remote, "remote cannot be nil")
  return git({ "remote", "get-url", remote })[1]
end

local function get_git_rev(revspec)
  return git({ "rev-parse", revspec })[1]
end

local function get_git_rev_name(revspec)
  return git({ "rev-parse", "--abbrev-ref", revspec })[1]
end

local function get_git_root()
  return git({ "rev-parse", "--show-toplevel" }, buffer_dir())[1]
end

local function get_jj_root()
  local output, code = command("jj", { "root" }, buffer_dir())
  if code ~= 0 then
    return nil
  end

  local root = output[1]
  local _, log_code = command(
    "jj",
    { "log", "--no-graph", "--revisions", "@", "--template", "commit_id" },
    root
  )
  if log_code ~= 0 then
    return nil
  end
  return root
end

local function is_jj_repo()
  return get_jj_root() ~= nil
end

local function get_jj_remotes()
  local output, code = jj({ "git", "remote", "list" })
  if code ~= 0 then
    return {}
  end

  local remotes = {}
  for _, line in ipairs(output) do
    local remote = line:match("^(%S+)")
    if remote then
      remotes[#remotes + 1] = remote
    end
  end
  return remotes
end

local function get_jj_remote_uri(remote)
  assert(remote, "remote cannot be nil")
  local output, code = jj({ "git", "remote", "list" })
  if code ~= 0 then
    return nil
  end

  for _, line in ipairs(output) do
    local name, uri = line:match("^(%S+)%s+(.+)$")
    if name == remote then
      return uri
    end
  end
  return nil
end

local function jj_quote(str)
  return '"' .. str:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function get_jj_rev(revset)
  local output, code = jj({
    "log",
    "--no-graph",
    "--revisions",
    revset,
    "--template",
    'commit_id ++ "\n"',
  })
  if code ~= 0 then
    return nil
  end
  return output[1]
end

local function is_git_file_in_rev(file, revspec)
  local _, code = git({ "cat-file", "-e", revspec .. ":" .. file })
  if code == 0 then
    return true
  end
  return false
end

local function is_jj_file_in_rev(file, revspec)
  local output, code = jj({ "file", "list", "--revision", revspec, "--", file })
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

function M.is_file_in_rev(file, revspec)
  if is_jj_repo() then
    return is_jj_file_in_rev(file, revspec)
  end

  if is_git_file_in_rev(file, revspec) then
    return true
  end
  return false
end

local function has_git_file_changed(file, rev)
  if git({ "diff", rev, "--", file })[1] then
    return true
  end
  return false
end

local function has_jj_file_changed(file, rev)
  return jj({ "diff", "--from", rev, "--to", "@", "--name-only", "--", file })[1]
    ~= nil
end

function M.has_file_changed(file, rev)
  if is_jj_repo() then
    return has_jj_file_changed(file, rev)
  end

  return has_git_file_changed(file, rev)
end

local function is_git_rev_in_remote(revspec, remote)
  assert(remote, "remote cannot be nil")
  local output = git({ "branch", "--remotes", "--contains", revspec })
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

local function get_git_closest_remote_compatible_rev(remote)
  -- try upstream branch HEAD (a.k.a @{u})
  local upstream_rev = get_git_rev("@{u}")
  if upstream_rev then
    return upstream_rev
  end

  -- try HEAD
  if is_git_rev_in_remote("HEAD", remote) then
    local head_rev = get_git_rev("HEAD")
    if head_rev then
      return head_rev
    end
  end

  -- try last 50 parent commits
  for i = 1, 50 do
    local revspec = "HEAD~" .. i
    if is_git_rev_in_remote(revspec, remote) then
      local rev = get_git_rev(revspec)
      if rev then
        return rev
      end
    end
  end

  -- try remote HEAD
  local remote_rev = get_git_rev(remote)
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

local function get_jj_closest_remote_compatible_rev(remote)
  local remote_bookmarks = "remote_bookmarks(remote=" .. jj_quote(remote) .. ")"
  local ancestor = get_jj_rev("latest(::@ & " .. remote_bookmarks .. ", 1)")
  if ancestor then
    return ancestor
  end

  local remote_rev = get_jj_rev("latest(" .. remote_bookmarks .. ", 1)")
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

function M.get_closest_remote_compatible_rev(remote)
  if is_jj_repo() then
    return get_jj_closest_remote_compatible_rev(remote)
  end

  return get_git_closest_remote_compatible_rev(remote)
end

function M.get_repo_data(remote)
  local errs = {
    string.format("Failed to retrieve repo data for remote '%s'", remote),
  }
  local remote_uri
  if is_jj_repo() then
    remote_uri = get_jj_remote_uri(remote)
  else
    remote_uri = get_git_remote_uri(remote)
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
  return get_jj_root() or get_git_root()
end

local function get_git_branch_remote()
  local remotes = get_git_remotes()
  if #remotes == 0 then
    vim.notify("Git repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  local upstream_branch = get_git_rev_name("@{u}")
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

local function get_jj_branch_remote()
  local remotes = get_jj_remotes()
  if #remotes == 0 then
    vim.notify("JJ repo has no remote", vim.log.levels.ERROR)
    return nil
  end
  if #remotes == 1 then
    return remotes[1]
  end

  return nil
end

function M.get_branch_remote()
  if is_jj_repo() then
    return get_jj_branch_remote()
  end

  return get_git_branch_remote()
end

return M
