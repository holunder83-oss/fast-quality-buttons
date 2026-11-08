-- 5 quality buttons in the vanilla shortcut bar (show/hide them via the bar's "..." menu).
local qualities = { "normal", "uncommon", "rare", "epic", "legendary" }

for i, name in pairs(qualities) do
  local q = data.raw.quality and data.raw.quality[name]
  local icons
  if q and q.icons then
    icons = q.icons
  elseif q and q.icon then
    icons = { { icon = q.icon, icon_size = q.icon_size or 64 } }
  else
    icons = { { icon = "__core__/graphics/icons/unknown.png", icon_size = 64 } }
  end

  data:extend({
    {
      type = "shortcut",
      name = "fqb-" .. name,
      order = "z[fqb]-" .. i,
      action = "lua",
      toggleable = true,
      icons = icons,
      small_icons = icons,
      localised_name = { "shortcut-name.fqb", { "quality-name." .. name } },
    },
  })
end
