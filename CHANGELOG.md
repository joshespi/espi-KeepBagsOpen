# Changelog

## 1.0.2

- Final release. Keep Bags Open is now part of Espi Utils and gets no more updates. Install Espi Utils and disable this addon; your settings are copied over on first load.
- Shows a one-time notice in chat per character. Behavior is unchanged.

## 1.0.1

- Bags are no longer reopened during combat; they come back when combat ends. Bags reopened by an addon are tainted, which could block using items from them.
- When the game blocks an action and blames this addon, it prints the blocked function and saves it. `/kbo blocked` lists them, `/kbo blocked clear` empties the list.

## 1.0.0

- Initial release.
- Bags you had open are reopened when the game closes them (loot, vendors, mail, Escape closing other windows, and so on).
- Bags only stay closed when you close them yourself.
- `/kbo [on|off]` (or `/keepbags`) toggles the addon.
- `/kbo status` and `/kbo config` commands, a settings checkbox, and a retail addon compartment toggle.
