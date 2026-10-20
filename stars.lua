#!/usr/bin/env -S nvim -l

-- Keep GitHub stars and star lists in sync with stars.json, and render them
-- into README.md between the `<!-- stars:start -->` and `<!-- stars:end -->`
-- markers.
--
-- Usage:
--    ./stars.lua -h

assert(vim.fn.executable('gh') == 1)

local root = vim.fs.dirname(vim.fs.abspath(_G.arg[0]))
local stars_file = vim.fs.joinpath(root, 'stars.json')
local readme_file = vim.fs.joinpath(root, 'README.md')
local backup_file = vim.fs.joinpath(vim.fn.stdpath('cache'), 'stars-backup.json')

local stars_start = '<!-- stars:start -->'
local stars_end = '<!-- stars:end -->'
local uncategorized = 'Uncategorized'

local function die(msg)
  print(msg)
  vim.cmd('cquit 1')
end

--- Run a command, die on failure with err_msg
--- @param cmd string[]
--- @param err_msg string
--- @return string
local function run_die(cmd, err_msg)
  local rv = vim.system(cmd, { text = true }):wait()
  if rv.code ~= 0 then
    die(('%s\n%s'):format(err_msg, vim.trim(rv.stderr or '')))
  end
  return rv.stdout
end

--- @param path string
--- @return string?
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local s = f:read('*a')
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

--- @param path string
--- @param obj any
local function write_json(path, obj)
  write_file(path, vim.json.encode(obj, { indent = '  ', sort_keys = true }) .. '\n')
end

--- Every variable is sent with `-f` (as a string). `-F` would type-guess, so
--- a repo named "2024" would go out as an Int and fail against `String!`.
--- @param query string
--- @param vars table<string, string>?
--- @return table
local function graphql(query, vars)
  local cmd = { 'gh', 'api', 'graphql', '-f', 'query=' .. query }
  for k, v in vim.spairs(vars or {}) do
    vim.list_extend(cmd, { '-f', ('%s=%s'):format(k, v) })
  end
  local out = run_die(
    cmd,
    'gh api graphql failed (missing scope? try `gh auth refresh -h github.com -s user`)'
  )
  -- luanil drops JSON nulls, for example an empty repo description.
  return vim.json.decode(out, { luanil = { object = true } }).data
end

local page_info = 'pageInfo { hasNextPage endCursor }'

--- Follows a GraphQL connection to the end.
--- @param first table connection that was already fetched
--- @param next_page fun(cursor: string): table fetches the connection after `cursor`
--- @return table[]
local function paginate(first, next_page)
  local nodes, conn = {}, first
  while true do
    vim.list_extend(nodes, conn.nodes)
    if not conn.pageInfo.hasNextPage then
      return nodes
    end
    conn = next_page(conn.pageInfo.endCursor)
  end
end

--- @class stars.Repo
--- @field id string
--- @field nameWithOwner string
--- @field url string
--- @field description? string

--- @class stars.List
--- @field id string
--- @field name string
--- @field repos string[] sorted repo names

--- @class stars.State
--- @field repos table<string, stars.Repo> starred repos by name
--- @field lists table<string, stars.List> lists by name

--- Fetches every starred repo and every list from GitHub.
--- @return stars.State
local function fetch()
  local starred_query = ([[
    query($cursor: String) {
      viewer {
        starredRepositories(first: 100, after: $cursor) {
          %s nodes { id nameWithOwner url description }
        }
      }
    }]]):format(page_info)
  local lists_query = ([[
    query($cursor: String) {
      viewer {
        lists(first: 100, after: $cursor) {
          %s nodes {
            id name
            items(first: 100) { %s nodes { ... on Repository { nameWithOwner } } }
          }
        }
      }
    }]]):format(page_info, page_info)
  local items_query = ([[
    query($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on UserList {
          items(first: 100, after: $cursor) { %s nodes { ... on Repository { nameWithOwner } } }
        }
      }
    }]]):format(page_info)

  local starred = paginate(graphql(starred_query).viewer.starredRepositories, function(cursor)
    return graphql(starred_query, { cursor = cursor }).viewer.starredRepositories
  end)
  local lists = paginate(graphql(lists_query).viewer.lists, function(cursor)
    return graphql(lists_query, { cursor = cursor }).viewer.lists
  end)

  local state = { repos = {}, lists = {} } --- @type stars.State
  for _, repo in ipairs(starred) do
    state.repos[repo.nameWithOwner] = repo
  end
  for _, list in ipairs(lists) do
    local items = paginate(list.items, function(cursor)
      return graphql(items_query, { id = list.id, cursor = cursor }).node.items
    end)
    local repos = vim
      .iter(items)
      :map(function(item)
        return item.nameWithOwner -- nil for anything that is not a repository
      end)
      :totable()
    table.sort(repos)
    state.lists[list.name] = { id = list.id, name = list.name, repos = repos }
  end
  return state
end

--- Repo names that are not in any list.
--- @param state stars.State
--- @return string[]
local function uncategorized_repos(state)
  local listed = {} --- @type table<string, true>
  for _, list in pairs(state.lists) do
    for _, r in ipairs(list.repos) do
      listed[r] = true
    end
  end
  local out = vim.tbl_filter(function(r)
    return not listed[r]
  end, vim.tbl_keys(state.repos))
  table.sort(out)
  return out
end

--- @param state stars.State
local function render_readme(state)
  local lines = {} --- @type string[]

  local function section(title, repos)
    lines[#lines + 1] = ('### %s (%d)'):format(title, #repos)
    lines[#lines + 1] = ''
    for _, name in ipairs(repos) do
      local repo = state.repos[name] or { url = 'https://github.com/' .. name }
      local desc = repo.description and (' — ' .. vim.trim(repo.description)) or ''
      lines[#lines + 1] = ('- [%s](%s)%s'):format(name, repo.url, desc)
    end
    lines[#lines + 1] = ''
  end

  for name, list in vim.spairs(state.lists) do
    section(name, list.repos)
  end
  section(uncategorized, uncategorized_repos(state))

  local readme = read_file(readme_file) or die('cannot read ' .. readme_file)
  local i = readme:find(stars_start, 1, true)
  local j = readme:find(stars_end, 1, true)
  if not i or not j or j < i then
    die(('%s/%s markers not found or out of order in %s'):format(stars_start, stars_end, readme_file))
  end
  write_file(
    readme_file,
    readme:sub(1, i + #stars_start - 1) .. '\n' .. table.concat(lines, '\n') .. readme:sub(j)
  )
end

local function pull()
  local state = fetch()
  local out = { [uncategorized] = uncategorized_repos(state) } --- @type table<string, string[]>
  for name, list in pairs(state.lists) do
    out[name] = list.repos
  end
  write_json(stars_file, out)
  render_readme(state)
  print(
    ('wrote %s and README.md (%d starred, %d lists)'):format(
      vim.fs.basename(stars_file),
      vim.tbl_count(state.repos),
      vim.tbl_count(state.lists)
    )
  )
end

--- Reads stars.json into the shape `sync` diffs against.
--- @return table<string, table<string, true>> membership repo -> set of list names
--- @return table<string, true> lists set of list names
local function read_wanted()
  local text = read_file(stars_file) or die(stars_file .. ' not found -- run `./stars.lua pull` first')
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= 'table' then
    die(('%s is not valid JSON: %s'):format(stars_file, data))
  end
  local membership, lists = {}, {}
  for name, repos in pairs(data) do
    if name ~= uncategorized then
      lists[name] = true
    end
    for _, r in ipairs(repos) do
      membership[r] = membership[r] or {}
      if name ~= uncategorized then
        membership[r][name] = true
      end
    end
  end
  return membership, lists
end

--- Keys of `a` that are not in `b`, sorted.
--- @param a table
--- @param b table
--- @return string[]
local function missing(a, b)
  local out = vim.tbl_filter(function(k)
    return b[k] == nil
  end, vim.tbl_keys(a))
  table.sort(out)
  return out
end

--- @param set table<string, true>
--- @return string[]
local function sorted(set)
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- @param apply boolean
local function sync(apply)
  local want, want_lists = read_wanted()
  local state = fetch()

  local plan = {
    star = missing(want, state.repos),
    unstar = missing(state.repos, want),
    create = missing(want_lists, state.lists),
    delete = missing(state.lists, want_lists),
    reassign = {}, --- @type string[]
  }

  -- Current membership, ignoring lists that are about to be deleted.
  local have = {} --- @type table<string, table<string, true>>
  for name, list in pairs(state.lists) do
    if want_lists[name] then
      for _, r in ipairs(list.repos) do
        have[r] = have[r] or {}
        have[r][name] = true
      end
    end
  end
  -- Includes repos that are about to be starred, so they land in their lists
  -- in the same run.
  for _, r in ipairs(sorted(want)) do
    if not vim.deep_equal(want[r], have[r] or {}) then
      plan.reassign[#plan.reassign + 1] = r
    end
  end

  for _, r in ipairs(plan.star) do
    print('+ star     ' .. r)
  end
  for _, r in ipairs(plan.unstar) do
    print('- unstar   ' .. r)
  end
  for _, name in ipairs(plan.create) do
    print(('+ list     "%s"'):format(name))
  end
  for _, name in ipairs(plan.delete) do
    print(('- list     "%s"'):format(name))
  end
  for _, r in ipairs(plan.reassign) do
    print(('~ %s -> [%s]'):format(r, table.concat(sorted(want[r]), ', ')))
  end

  local total = #plan.star + #plan.unstar + #plan.create + #plan.delete + #plan.reassign
  if total == 0 then
    print('already in sync')
    return
  end
  print(
    ('\n%d star, %d unstar, %d create, %d delete, %d reassign'):format(
      #plan.star,
      #plan.unstar,
      #plan.create,
      #plan.delete,
      #plan.reassign
    )
  )
  if not apply then
    print('dry run -- re-run with --apply to push these changes')
    return
  end

  -- Resolve every repo id before changing anything, so a typo in stars.json
  -- fails here instead of halfway through.
  local ids = {} --- @type table<string, string>
  for name, repo in pairs(state.repos) do
    ids[name] = repo.id
  end
  for _, r in ipairs(plan.star) do
    local owner, name = r:match('^([^/]+)/([^/]+)$')
    if not owner then
      die(('invalid repo name "%s" in %s'):format(r, stars_file))
    end
    local repo = graphql(
      'query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }',
      { owner = owner, name = name }
    ).repository
    ids[r] = repo and repo.id or die(('repo "%s" not found'):format(r))
  end

  -- Snapshot GitHub as it stood right before the changes, so a bad apply can
  -- be inspected or reverted by hand.
  vim.fn.mkdir(vim.fs.dirname(backup_file), 'p')
  write_json(backup_file, state)
  print('backed up current state to ' .. backup_file)

  for _, r in ipairs(plan.unstar) do
    graphql(
      'mutation($id: ID!) { removeStar(input: { starrableId: $id }) { clientMutationId } }',
      { id = ids[r] }
    )
    print('unstarred ' .. r)
  end
  for _, r in ipairs(plan.star) do
    graphql(
      'mutation($id: ID!) { addStar(input: { starrableId: $id }) { clientMutationId } }',
      { id = ids[r] }
    )
    print('starred ' .. r)
  end

  local list_ids = {} --- @type table<string, string>
  for name, list in pairs(state.lists) do
    list_ids[name] = list.id
  end
  for _, name in ipairs(plan.create) do
    list_ids[name] = graphql(
      'mutation($name: String!) { createUserList(input: { name: $name }) { list { id } } }',
      { name = name }
    ).createUserList.list.id
    print(('created list "%s"'):format(name))
  end
  for _, name in ipairs(plan.delete) do
    graphql(
      'mutation($id: ID!) { deleteUserList(input: { listId: $id }) { clientMutationId } }',
      { id = list_ids[name] }
    )
    print(('deleted list "%s"'):format(name))
  end

  for _, r in ipairs(plan.reassign) do
    local names = sorted(want[r])
    -- An array cannot be sent with `-f`, so the ids go into the query itself.
    local list_json = vim.json.encode(vim.tbl_map(function(n)
      return list_ids[n]
    end, names))
    graphql(
      ('mutation($id: ID!) { updateUserListsForItem(input: { itemId: $id, listIds: %s }) { clientMutationId } }'):format(
        list_json
      ),
      { id = ids[r] }
    )
    print(('%s -> [%s]'):format(r, table.concat(names, ', ')))
  end

  print('\ndone -- run `./stars.lua pull` to refresh stars.json and README.md')
end

local function usage()
  local this_script = './' .. vim.fs.basename(_G.arg[0])
  print(([=[
    Sync GitHub stars and star lists with stars.json

    Usage:  %s <command> [options]
        %s pull            fetch GitHub into stars.json and README.md
        %s sync            show what syncing stars.json would change on GitHub
        %s sync --apply    push those changes to GitHub

    Options:
        -h, --help            show this message and exit.
        --apply               (sync) make the changes instead of a dry run.

    stars.json maps each list name to the repos in it ("owner/name"). Repos in
    no list go under "%s". A repo may be in several lists.
  ]=]):format(this_script, this_script, this_script, this_script, uncategorized))
end

do
  local args = {}
  for _, a in ipairs(_G.arg) do
    if a == '-h' or a == '--help' then
      args.h = true
    elseif a == '--apply' then
      args.apply = true
    elseif vim.startswith(a, '-') then
      die(('Invalid argument %s\n'):format(a))
    elseif not args.command then
      args.command = a
    else
      die(('Unexpected argument %s\n'):format(a))
    end
  end

  if args.h or not args.command then
    usage()
  elseif args.command == 'pull' then
    pull()
  elseif args.command == 'sync' then
    sync(args.apply == true)
  else
    usage()
    die(('Unknown command %s\n'):format(args.command))
  end
end
