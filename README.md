# Industry Supply Links (Transport Fever 2 mod)

Open an industry window and select the **Suppliers** tab: rows of filled coloured arrows (at least 5 per
connection, never more than 150 m apart) are drawn on the ground/map from every industry that *could* supply it (it produces
a cargo this industry accepts), pointing at the industry that receives the cargo. The **Consumers** tab does the same in the other direction.
Arrows disappear when you switch to another tab or close the window.

**Towns** work the same way: open a town and arrows are drawn from every industry that produces a
cargo the town needs right now (demand above 0; cargo it will only want once it grows is skipped) when its **Suppliers** tab is selected. The tab
is found by its caption, otherwise the town window's last tab is used. The tab-position settings
below apply to industry windows only.

- One colour per cargo type. A small "Supply links" window shows a square in each colour, the
  cargo's icon and name and how many industries are linked (e.g. `10 / 23` = nearest 10 of 23 shown).
- The **Show arrows** switch at the top of that window turns the arrows off and on (the rings stay).
  Next to it, **Lines: 5 / 10 / 20 / All** changes how many industries per cargo are linked.
  Both choices are saved with the game; until you pick one, the mod settings apply.
- White ring = the industry you opened. Coloured ring = a possible supplier/consumer.
- These are *possible* links (matching cargo), not current deliveries.

## Install

1. Unzip so that you get the folder `industry_supply_links_1` (the folder name must keep the `_1`).
2. Move that folder into your Transport Fever 2 **mods** folder:
   - Steam: `<Steam>\steamapps\common\Transport Fever 2\mods\`
     (Steam → right-click Transport Fever 2 → Manage → Browse local files → `mods`)
   - It should end up as `...\Transport Fever 2\mods\industry_supply_links_1\mod.lua`.
3. Start the game, then **New game** or **Load game** → *Mods* → enable
   **Industry Supply Links**. For an existing save, enable it in the load-game mod list.
4. In game: click an industry → select the **Suppliers** tab.

## Settings (in the mod list, before starting/loading)

| Setting | Meaning |
|---|---|
| Lines per cargo | Only the nearest 5 / 10 / 20 / all industries per cargo are linked. |
| Arrow size | Thin, Normal, Wide. |
| Filled arrows | Fill the inside of each arrow (drawn as nested outlines). |
| Lines on Consumers tab | Also draw lines on the Consumers tab. |
| Town suppliers | Draw arrows to towns from industries producing the cargo they need. |
| Legend window | Show the colour legend window. |
| Suppliers / Consumers tab position | *Auto* finds the tab by its caption. If no lines appear, set its position counted from the left (1 = first tab). |
| Debug log | Writes detection details to `stdout.txt` (lines start with `[IndustrySupplyLinks]`). |

## How it works

- `mod.lua` reads each industry's recipe while the game loads (the `stockListConfig` used by
  vanilla industries and most modded ones) and passes it to the game script through `game.config`.
- A built-in table of the 16 vanilla industries is used as a fallback, and cargo an industry has
  actually produced/consumed is added on top.
- `res/config/game_script/industry_supply_links.lua` watches for industry windows
  (`temp.view.entity_<id>`), finds the window's tab widget, checks which tab is selected
  every few frames, and draws lines with `game.interface.setZone` (ground polygons).

## Known limits

- TF2 has no "draw a line" API for the map, so the arrows are ground zones. They follow the
  terrain, and they follow the straight line between industries (not routes).
- On an industry's Consumers tab, towns are not shown yet (only industries).
- Modded industries whose recipe is not built from `stockListConfig` only get lines once they
  have produced/consumed something.
- Tab detection by caption covers English, Czech, German, French, Spanish, Italian, Polish,
  Portuguese, Dutch, Slovak, Hungarian, Russian, Chinese and Japanese; otherwise set the tab position.
