#!/usr/bin/env -S nvim -l

-- List and sync GitHub starred repos with nvim
-- TODO: set this up as a dir provider for browsing
--
-- Usage:
--   ./stars.lua pull          fetch current GitHub state into stars.json + README.md
--   ./stars.lua sync          dry run: show what would change on GitHub
--   ./stars.lua sync --apply  push those changes for real

assert(vim.fn.executable('gh') == 1)

local nv = require('nvim')

local root = vim.fs.dirname(vim.fs.abspath(_G.arg[0]))
local json_path = nv.cache_path('stars.json')
local state_name = 'stars-state.json'
local readme_path = vim.fs.joinpath(root, 'README.md')
local stars_start = '<!-- stars:start -->'
local stars_end = '<!-- stars:end -->'
local uncategorized = 'Uncategorized'

local color = {
  reset = '\27[0m',
  dim = '\27[2m',
  red = '\27[31m',
  green = '\27[32m',
  yellow = '\27[33m',
  cyan = '\27[36m',
}

local is_tty = vim.uv.guess_handle(1) == 'tty'

--- @param text string
--- @param c string
--- @return string
local function paint(text, c)
  return is_tty and (c .. text .. color.reset) or text
end

--- @param msg string
local function die(msg)
  print(paint(msg, color.red))
  vim.cmd('cquit 1')
end

--- @param path string
--- @return string
local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local s = f:read('a')
  f:close()
  return s
end

--- @param path string
--- @param s string
local function write_file(path, s)
  local f = assert(io.open(path, 'w'))
  f:write(s)
  f:close()
end

--- @param t table<string, any>
--- @return string[]
local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return keys
end

--- @param query string
--- @param variables table<string, string>?
--- @return table
local function gh_graphql(query, variables)
  -- `-f` sends every variable as a string. `-F` would type-guess and send a
  -- name like "2024" as an Int, which fails against a String! variable.
  local cmd = { 'gh', 'api', 'graphql', '-f', 'query=' .. query }
  for k, v in pairs(variables or {}) do
    cmd[#cmd + 1] = '-f'
    cmd[#cmd + 1] = string.format('%s=%s', k, v)
  end
  local rv = vim.system(cmd):wait()
  if rv.code ~= 0 then
    local err = vim.trim(rv.stderr)
    if err:find('required scopes') then
      err = err .. '\nrun `gh auth refresh -h github.com -s user` to grant the missing scope'
    end
    die('gh graphql failed: ' .. err)
  end
  -- luanil drops JSON null fields, for example an empty repo description.
  return vim.json.decode(rv.stdout, { luanil = { object = true } }).data
end

--- @param method string
--- @param path string
local function gh_rest(method, path)
  local rv = vim.system({ 'gh', 'api', '-X', method, path }):wait()
  if rv.code ~= 0 then
    die(string.format('gh api %s %s failed: %s', method, path, vim.trim(rv.stderr)))
  end
end

local repo_fields = '{ id nameWithOwner url description }'

local lists_query = string.format(
  [[
        lists(first: 50) {
          nodes { id name items(first: 100) { nodes { ... on Repository %s } } }
        }]],
  repo_fields
)

--- Fetches the lists and every starred repo. The first request carries the
--- list query, so a small account costs one `gh` call instead of two.
--- @return table[] lists
--- @return table[] starred
local function fetch_remote()
  local lists ---@type table[]?
  local starred = {} --- @type table[]
  local cursor = ''
  while true do
    local viewer = gh_graphql(
      string.format(
        [[
      query($cursor: String) {
        viewer {%s
          starredRepositories(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes %s
          }
        }
      }
      ]],
        lists and '' or lists_query,
        repo_fields
      ),
      { cursor = cursor }
    ).viewer
    lists = lists or viewer.lists.nodes
    local page = viewer.starredRepositories
    vim.list_extend(starred, page.nodes)
    if not page.pageInfo.hasNextPage then
      return lists, starred
    end
    cursor = page.pageInfo.endCursor
  end
end

--- Reads the remote state through `stdpath('cache')/stars-state.json`.
--- `fresh` skips the cache and refills it, for `pull` and for `sync --apply`.
--- @param fresh boolean
--- @return table[] lists
--- @return table[] starred
local function fetch_state(fresh)
  if fresh then
    os.remove(nv.cache_path(state_name))
  end
  local state = nv.cached(state_name, function()
    local lists, starred = fetch_remote()
    return { lists = lists, starred = starred }
  end)
  return state.lists, state.starred
end

--- @param lists table[]
--- @param uncategorized_repos string[]
local function write_json(lists, uncategorized_repos)
  local out = { [uncategorized] = uncategorized_repos } --- @type table<string, string[]>
  for _, l in ipairs(lists) do
    out[l.name] = vim.iter(l.items.nodes):map(function(n)
      return n.nameWithOwner
    end):totable()
  end
  for _, repos in pairs(out) do
    table.sort(repos)
  end
  nv.json.write(json_path, out)
end

--- @param lines string[]
--- @param nodes table[]
--- @param name string
local function readme_section(lines, nodes, name)
  table.sort(nodes, function(a, b)
    return a.nameWithOwner < b.nameWithOwner
  end)
  lines[#lines + 1] = string.format('### %s (%d)', name, #nodes)
  lines[#lines + 1] = ''
  for _, n in ipairs(nodes) do
    local desc = n.description and (' — ' .. n.description) or ''
    lines[#lines + 1] = string.format('- [%s](%s)%s', n.nameWithOwner, n.url, desc)
  end
end

--- @param lists table[]
--- @param uncategorized_nodes table[]
local function write_readme_stars(lists, uncategorized_nodes)
  local lines = {}
  for _, l in ipairs(lists) do
    readme_section(lines, l.items.nodes, l.name)
    lines[#lines + 1] = ''
  end
  readme_section(lines, uncategorized_nodes, uncategorized)

  local readme = read_file(readme_path)
  local start_marker = readme:find(stars_start, 1, true)
  local end_marker = readme:find(stars_end, 1, true)
  if not start_marker or not end_marker or end_marker < start_marker then
    die(string.format('%s/%s markers not found or out of order in README.md', stars_start, stars_end))
  end
  local head = readme:sub(1, start_marker + #stars_start - 1)
  write_file(readme_path, head .. '\n' .. table.concat(lines, '\n') .. '\n' .. readme:sub(end_marker))
end

local function cmd_pull()
  local lists, starred = fetch_state(true)

  local categorized = vim.iter(lists):fold({}, function(acc, l)
    for _, n in ipairs(l.items.nodes) do
      acc[n.nameWithOwner] = true
    end
    return acc
  end)

  local rest = vim.iter(starred):filter(function(n)
    return not categorized[n.nameWithOwner]
  end):totable()
  local rest_names = vim.iter(rest):map(function(n)
    return n.nameWithOwner
  end):totable()

  write_json(lists, rest_names)
  write_readme_stars(lists, rest)
  print(
    paint('wrote ' .. json_path .. ' and updated README.md', color.green)
      .. string.format(' (%d starred, %d lists)', #starred, #lists)
  )
end

--- @return table<string, true> repos
--- @return table<string, table<string, true>> membership
--- @return table<string, true> lists
local function load_desired()
  local data = nv.json.read(json_path)
  if not data then
    die(string.format('%s not found or invalid -- run `./stars.lua pull` first', json_path))
  end
  local repos = {} --- @type table<string, true>
  local membership = vim.defaulttable() --- @type table<string, table<string, true>>
  local lists = {} --- @type table<string, true>
  for name, list_repos in pairs(data) do
    for _, r in ipairs(list_repos) do
      repos[r] = true
      if name ~= uncategorized then
        membership[r][name] = true
      end
    end
    if name ~= uncategorized then
      lists[name] = true
    end
  end
  return repos, membership, lists
end

--- Keys of `a` that `b` does not have, sorted.
--- @param a table<string, any>
--- @param b table<string, any>
--- @return string[]
local function difference(a, b)
  local out = vim.iter(a):map(function(k)
    return b[k] == nil and k or nil
  end):totable()
  table.sort(out)
  return out
end

local cmd_sync ---@type fun(apply: boolean)

--- @return boolean
local function confirm()
  if vim.uv.guess_handle(0) ~= 'tty' then
    print(paint('\ndry run -- no changes made. re-run with --apply to push.', color.yellow))
    return false
  end
  io.write(paint('\napply these changes? [y/N] ', color.yellow))
  local answer = (io.read('l') or ''):lower()
  if answer ~= 'y' and answer ~= 'yes' then
    print(paint('aborted -- no changes made.', color.yellow))
    return false
  end
  return true
end

--- @param apply boolean
function cmd_sync(apply)
  local desired_repos, desired_membership, desired_lists = load_desired()

  -- `--apply` refetches, so the mutations run against current GitHub state.
  local lists, starred = fetch_state(apply)

  local id_map = vim.iter(starred):fold({}, function(acc, n)
    acc[n.nameWithOwner] = n.id
    return acc
  end)
  local current_repos = vim.iter(starred):fold({}, function(acc, n)
    acc[n.nameWithOwner] = true
    return acc
  end)

  local current_lists = {} --- @type table<string, table>
  local current_membership = vim.defaulttable() --- @type table<string, table<string, true>>
  for _, l in ipairs(lists) do
    current_lists[l.name] = l
    for _, n in ipairs(l.items.nodes) do
      current_membership[n.nameWithOwner][l.name] = true
    end
  end

  local to_star = difference(desired_repos, current_repos)
  local to_unstar = difference(current_repos, desired_repos)
  local to_create = difference(desired_lists, current_lists)
  local to_delete = difference(current_lists, desired_lists)

  local function count(label, items, c)
    print(paint(string.format('%s %d', label, #items), #items > 0 and c or color.dim))
  end
  count('star:       ', to_star, color.green)
  count('unstar:     ', to_unstar, color.red)
  count('create list:', to_create, color.green)
  count('delete list:', to_delete, color.red)

  for _, r in ipairs(to_star) do
    print(paint('  + star   ' .. r, color.green))
  end
  for _, r in ipairs(to_unstar) do
    print(paint('  - unstar ' .. r, color.red))
  end
  for _, name in ipairs(to_create) do
    print(paint(string.format('  + list   "%s"', name), color.green))
  end
  for _, name in ipairs(to_delete) do
    print(paint(string.format('  - list   "%s"', name), color.red))
  end

  local moved = vim.iter(desired_repos):map(function(r)
    local changed = not vim.deep_equal(desired_membership[r], current_membership[r])
    return (current_repos[r] and changed) and r or nil
  end):totable()
  table.sort(moved)

  count('reassign membership:', moved, color.cyan)
  for _, r in ipairs(moved) do
    local want = sorted_keys(desired_membership[r])
    print(paint(string.format('  ~ %s -> %s', r, vim.inspect(want)), color.cyan))
  end

  if #to_star + #to_unstar + #to_create + #to_delete + #moved == 0 then
    print(paint('\nalready in sync -- nothing to do.', color.green))
    return
  end

  if not apply then
    if not confirm() then
      return
    end
    -- The diff above can come from the cache. Refetch, then apply without
    -- asking a second time.
    return cmd_sync(true)
  end

  for _, r in ipairs(to_unstar) do
    gh_rest('DELETE', '/user/starred/' .. r)
    print(paint('unstarred ' .. r, color.red))
  end

  for _, r in ipairs(to_star) do
    local owner, name = r:match('^([^/]+)/(.+)$')
    gh_rest('PUT', '/user/starred/' .. r)
    local node = gh_graphql(
      'query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){ id } }',
      { owner = owner, name = name }
    )
    id_map[r] = node.repository.id
    print(paint('starred ' .. r, color.green))
  end

  local list_id_map = vim.iter(current_lists):fold({}, function(acc, name, l)
    acc[name] = l.id
    return acc
  end)

  for _, name in ipairs(to_create) do
    local data = gh_graphql(
      'mutation($name:String!){ createUserList(input:{name:$name}) { list { id name } } }',
      { name = name }
    )
    list_id_map[name] = data.createUserList.list.id
    print(paint(string.format('created list "%s"', name), color.green))
  end

  for _, name in ipairs(to_delete) do
    gh_graphql(
      'mutation($id:ID!){ deleteUserList(input:{listId:$id}) { clientMutationId } }',
      { id = current_lists[name].id }
    )
    print(paint(string.format('deleted list "%s"', name), color.red))
  end

  for _, r in ipairs(moved) do
    local want = sorted_keys(desired_membership[r])
    local list_ids = vim.json.encode(vim.iter(want):map(function(n)
      return list_id_map[n]
    end):totable())
    gh_graphql(
      string.format(
        'mutation($itemId:ID!){ updateUserListsForItem(input:{itemId:$itemId, listIds:%s}) { clientMutationId } }',
        list_ids
      ),
      { itemId = id_map[r] }
    )
    print(paint(string.format('reassigned %s -> %s', r, vim.inspect(want)), color.cyan))
  end

  -- GitHub changed, so the cached snapshot is wrong now.
  os.remove(nv.cache_path(state_name))
  print(paint('\napplied.', color.green) .. ' run `./stars.lua pull` to refresh local files.')
end

local function usage()
  print(string.format(
    [[
Usage: ./stars.lua <command>

  pull            fetch GitHub state into stars.json + README.md
  sync            diff stars.json against GitHub (dry run by default)
  sync --apply    push changes for real

stars.json:  %s
cached state: %s (pull and `sync --apply` refresh it)]],
    json_path,
    nv.cache_path(state_name)
  ))
end

do
  local command = _G.arg[1]
  local apply = false
  for i = 2, #_G.arg do
    if _G.arg[i] == '--apply' then
      apply = true
    else
      die('invalid argument ' .. _G.arg[i])
    end
  end

  if command == 'pull' then
    cmd_pull()

  elseif command == 'sync' then
    cmd_sync(apply)
  elseif command == '-h' or command == '--help' then
    usage()
  else
    usage()
    die('\nmissing or invalid command')
  end
end
