# RankUp

A World of Warcraft: Forever addon that keeps your action bars on the highest rank of the spells you choose.

In Forever, training a new rank of a mana ability doesn't update the copies already on your bars. RankUp lists your class abilities: tick the ones you want, and every time you train a new rank, the old rank is swapped out on every bar.

## Features

- A checklist of your class's active abilities (passives are left out), showing each spell's icon and current rank
- Ticked spells are upgraded on every bar when you train a new rank, when you tick them, and when you log in
- Unticked spells are never touched, so you can keep a downranked heal on purpose
- Upgrades wait until combat ends, and nothing you're dragging on the cursor gets dropped
- Choices are saved per character

## Install

1. Download the latest release (or **Code → Download ZIP**).
2. Copy the `RankUp` folder into `World of Warcraft\_forever_\Interface\AddOns\`, so the file ends up at `AddOns\RankUp\RankUp.toc`.
3. Restart the game, or type `/reload`.

## Usage

| Command | Action |
|---|---|
| `/rankup` or `/ru` | Open or close the window |
| `/rankup now` | Upgrade ticked spells right away |
| `/rankup all` | Tick every ability |
| `/rankup none` | Untick everything |
| `/rankup quiet` | Turn chat messages on or off |

You can also open it from the addon button on the minimap.

## Tests

The `test/` folder contains a mock game client:

```sh
lua5.1 test/harness.lua RankUp
```

## Compatibility

Built for WoW: Forever (Interface 16001).
