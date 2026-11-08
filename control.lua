local QUALITIES = { "normal", "uncommon", "rare", "epic", "legendary" }
local PREFIX = "fqb-"

local function init_storage()
  storage.selected = storage.selected or {} -- [player_index] = quality name | nil
  storage.watch = storage.watch or {}       -- [player_index] = { entity, recipe }
  storage.pending = storage.pending or {}   -- [player_index] = true: check cursor next tick
  storage.pipetted = storage.pipetted or {} -- [player_index] = true: last cursor change came from pipette
  -- clean up data from older versions
  storage.visible, storage.menu_open, storage.location = nil, nil, nil
end

local function sync_shortcuts(player)
  local selected = storage.selected[player.index]
  for _, q in pairs(QUALITIES) do
    if prototypes.shortcut[PREFIX .. q] then
      player.set_shortcut_toggled(PREFIX .. q, selected == q)
    end
  end
end

local function cleanup_old_gui(player)
  for _, root in pairs({ player.gui.screen, player.gui.top, player.gui.left }) do
    if root.fqb_frame then root.fqb_frame.destroy() end
  end
end

local function give_back(player, entity, items)
  if not items then return end
  for _, stack in pairs(items) do
    local inserted = player.insert(stack)
    local rest = stack.count - inserted
    if rest > 0 then
      entity.surface.spill_item_stack {
        position = entity.position,
        stack = { name = stack.name, count = rest, quality = stack.quality },
        enable_looted = true,
        force = player.force,
      }
    end
  end
end

-- Recipes whose quality must not be changed:
--  * any recipe with fixed/controlled ingredient quality (quality_min / quality_max / quality_change),
--    e.g. the "Quality Compressor" mod, whose recipes only work at recipe quality "normal"
--  * any recipe in a "quality-compression*" category (Quality Compressor, explicit safety net)
local excluded_cache = {}
local function is_excluded(recipe_name)
  local cached = excluded_cache[recipe_name]
  if cached ~= nil then return cached end

  local excluded = false
  local proto = prototypes.recipe[recipe_name]
  if proto then
    for _, category in pairs(proto.categories or {}) do
      if category:find("^quality%-compression") then
        excluded = true
        break
      end
    end
    for _, ing in pairs(proto.ingredients) do
      if ing.type == "item" and (ing.quality_min or ing.quality_max or ing.quality_change) then
        excluded = true
        break
      end
    end
  end
  excluded_cache[recipe_name] = excluded
  return excluded
end

-- If the player picked a new recipe in the watched machine, apply the selected quality.
-- Only reacts to recipe changes, so manually changing the quality in the GUI still works.
local function check_watch(player_index)
  local w = storage.watch[player_index]
  if not w then return end
  local entity = w.entity
  if not (entity and entity.valid) then
    storage.watch[player_index] = nil
    return
  end

  local recipe, quality = entity.get_recipe()
  local name = recipe and recipe.name or nil
  if name == w.recipe then return end
  w.recipe = name
  if not recipe then return end

  local selected = storage.selected[player_index]
  if not selected then return end
  if quality and quality.name == selected then return end
  if is_excluded(name) then return end

  local player = game.get_player(player_index)
  if not player then return end
  if not player.mod_settings["fqb-apply-recipes"].value then return end
  if not player.force.is_quality_unlocked(selected) then
    player.create_local_flying_text {
      text = { "fqb.quality-locked", { "quality-name." .. selected } },
      create_at_cursor = true,
    }
    return
  end

  local removed = entity.set_recipe(name, selected)
  give_back(player, entity, removed)
end

-------------------------------------------------------------------------------
-- Cursor: building from inventory, pipette and ghosts
-------------------------------------------------------------------------------

local function is_placeable(proto)
  return proto and (proto.place_result ~= nil or proto.place_as_tile_result ~= nil)
end

local function name_of(x)
  if type(x) == "string" then return x end
  return x and x.name
end

local function process_cursor(player)
  local selected = storage.selected[player.index]
  if not selected then return end
  if not player.force.is_quality_unlocked(selected) then return end

  local settings = player.mod_settings
  local from_pipette = storage.pipetted[player.index]
  storage.pipetted[player.index] = nil
  -- Taking items into the hand: pipette has its own switch, everything else is "build".
  local swap_items
  if from_pipette then
    swap_items = settings["fqb-apply-pipette"].value
  else
    swap_items = settings["fqb-apply-build"].value
  end
  local ghosts = settings["fqb-apply-ghosts"].value and (not from_pipette or settings["fqb-apply-pipette"].value)

  local inventory = player.get_main_inventory()
  local cursor = player.cursor_stack

  -- Item in hand
  if cursor and cursor.valid_for_read then
    if not swap_items or player.cursor_stack_temporary then return end
    if not is_placeable(cursor.prototype) then return end
    if cursor.quality.name == selected then return end
    if not inventory then return end
    local found = inventory.find_item_stack({ name = cursor.name, quality = selected })
    if not found then return end -- don't have it in that quality: keep what's in hand
    local name = cursor.name
    if player.clear_cursor() then
      found = inventory.find_item_stack({ name = name, quality = selected })
      if found then player.cursor_stack.transfer_stack(found) end
    end
    return
  end

  -- Ghost in hand (no items of that kind left / remote view)
  local ghost = player.cursor_ghost
  if ghost then
    local name = name_of(ghost.name)
    local quality = name_of(ghost.quality) or "normal"
    if not name or quality == selected then return end
    if not is_placeable(prototypes.item[name]) then return end
    -- Prefer real items of the selected quality if we have them
    if swap_items and inventory and player.cursor_stack then
      local found = inventory.find_item_stack({ name = name, quality = selected })
      if found then
        player.cursor_ghost = nil
        player.cursor_stack.transfer_stack(found)
        return
      end
    end
    if ghosts then
      player.cursor_ghost = { name = name, quality = selected }
    end
  end
end

script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
  storage.pending[event.player_index] = true
end)

script.on_event(defines.events.on_player_pipette, function(event)
  storage.pipetted[event.player_index] = true
  storage.pending[event.player_index] = true
end)

-- Processed one tick later so we know whether the change came from the pipette.
script.on_event(defines.events.on_tick, function()
  if not next(storage.pending) then return end
  local pending = storage.pending
  storage.pending = {}
  for player_index in pairs(pending) do
    local player = game.get_player(player_index)
    if player and player.valid then process_cursor(player) end
  end
  -- our own changes queue another check; it is a no-op, so drop it
  storage.pending = {}
  storage.pipetted = {}
end)

local function on_load_or_change()
  init_storage()
  for _, player in pairs(game.players) do
    cleanup_old_gui(player)
    sync_shortcuts(player)
  end
end

script.on_init(on_load_or_change)
script.on_configuration_changed(on_load_or_change)

script.on_event(defines.events.on_lua_shortcut, function(event)
  local name = event.prototype_name
  if name:sub(1, #PREFIX) ~= PREFIX then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local q = name:sub(#PREFIX + 1)
  if storage.selected[player.index] == q then
    storage.selected[player.index] = nil -- click active one again = off
  else
    storage.selected[player.index] = q
  end
  sync_shortcuts(player)
  storage.pending[player.index] = true -- also update what's currently in the hand
end)

script.on_event(defines.events.on_gui_opened, function(event)
  local entity = event.entity
  if entity and entity.valid and entity.type == "assembling-machine" then
    local recipe = entity.get_recipe()
    storage.watch[event.player_index] = { entity = entity, recipe = recipe and recipe.name or nil }
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if storage.watch[event.player_index] then
    check_watch(event.player_index)
    storage.watch[event.player_index] = nil
  end
end)

script.on_nth_tick(3, function()
  if not next(storage.watch) then return end
  for player_index in pairs(storage.watch) do
    check_watch(player_index)
  end
end)

script.on_event(defines.events.on_player_left_game, function(event)
  storage.watch[event.player_index] = nil
end)

script.on_event(defines.events.on_player_removed, function(event)
  storage.watch[event.player_index] = nil
  storage.selected[event.player_index] = nil
  storage.pending[event.player_index] = nil
  storage.pipetted[event.player_index] = nil
end)
