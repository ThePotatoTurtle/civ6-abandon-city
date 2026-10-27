# Abandon Cities

A Civilization VI mod for Gathering Storm. It lets you abandon one of your own cities over a few turns. The city shrinks, then it's removed from the map, and your nearby cities lose loyalty for a while.

Get it on the Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3828536309

Version 1.0.0.

## How it works

Open one of your cities and click **Abandon City** on the city panel. A popup shows:
- how many turns it takes;
- the population of the city on every turn;
- the loyalty penalty (strength, range and how long it lasts);
- which of your cities it will hit. Cities already under 50 loyalty get a warning, since the penalty could make them revolt or flip.

Confirm and it starts at once. The turn you click counts as turn 1.

Some basics:
- The city is removed at the end of its last turn.
- Growth and production carry on during the countdown. Anything that finishes is built as usual.
- At the start of each turn the population is cut down to the schedule. If the city grew, it's cut back. If it is already at or below the schedule (starvation, say), it is left alone.
- The city always ends with 1 population (starting size 1 to 4) or 2 (starting size 5 or more) on its last turn.
- Units in the city stay on the tile. The tiles become unowned.
- Only human players can abandon cities. The AI never does.

### Countdown, population and penalty by size

The size that counts is the population when you click Confirm (call it P0).

| P0 | Turns until removal | Population on the last turn | Loyalty lost per turn | Range (tiles) | Penalty lasts (turns) | Total per city |
|---|---|---|---|---|---|---|
| 1 | 3 | 1 | 4 | 6 | 6 | 24 |
| 2 | 3 | 1 | 4 | 6 | 6 | 24 |
| 3 to 4 | 3 | 1 | 5 | 7 | 6 | 30 |
| 5 | 4 | 2 | 5 | 7 | 8 | 40 |
| 6 to 8 | 4 | 2 | 6 | 8 | 8 | 48 |
| 9 | 4 | 2 | 7 | 9 | 8 | 56 |
| 10 to 12 | 5 | 2 | 7 | 9 | 10 | 70 |
| 15 | 5 | 2 | 8 | 10 | 10 | 80 |
| 20 or more | 5 | 2 | 10 | 12 | 10 | 100 |

- Turns until removal: 3 for P0 1 to 4, 4 for P0 5 to 9, 5 for P0 10 or more.
- Loyalty lost per turn grows from 4 at P0 1 to 10 at P0 20, and stays at 10 above that. The range grows from 6 tiles to 12 the same way. Both are rounded to the nearest whole number.
- The penalty lasts twice as long as the countdown: the countdown itself, then the same number of turns again after the city is gone. The range is measured from where the city stood.
- "Total per city" is what one affected city loses over the whole penalty if nothing else changes.

The population on each turn, for a few sizes:

| P0 | Turn 1 | Turn 2 | Turn 3 | Turn 4 | Turn 5 |
|---|---|---|---|---|---|
| 1 | 1 | 1 | 1, then removed | | |
| 4 | 4 | 3 | 1, then removed | | |
| 8 | 8 | 6 | 4 | 2, then removed | |
| 20 | 20 | 16 | 11 | 7 | 2, then removed |

The popup lists the schedule for the actual city.

### The loyalty penalty

- It hits your own cities within range, not the abandoned city itself and not anyone else's cities.
- It starts on the turn you click, so it already counts in that turn's loyalty.
- Cities are checked every turn. A city founded or captured inside the range during the penalty is hit too.
- Overlapping abandonments add up. A city covered by two of them loses both amounts.
- It uses the normal loyalty rules, so a weak city can still revolt or flip. It shows up in the city's loyalty breakdown as "Other effects".
- There are no amenity effects, and nothing is added to the war or grievance system.

## Cancelling

Click **Cancel Abandonment** on the same button, and confirm.

- The population you already lost stays lost.
- The loyalty penalty keeps going for as many turns as the abandonment ran. The turn you clicked and the turn you cancel both count: an abandonment that ran 2 turns keeps its penalty for 2 more.
- The city can't be abandoned again for 5 turns. After that, a new abandonment starts fresh from its current population.

## What blocks it

The button is greyed out, and its tooltip says why, when:
- the city is your capital;
- it is your last city;
- it is an original capital: yours (even after you move the palace) or one you captured;
- it was damaged in the last 5 turns (city centre or walls), or is under siege;
- an enemy military unit is within 6 tiles of the city centre. Enemies are players you are at war with, and Barbarians and Free Cities always count. Civilians don't. The tooltip only says "Enemy forces nearby";
- it is already being abandoned;
- it was cancelled less than 5 turns ago.

## Auto-cancel

The reason to block those cases is so you can't start an abandonment, watch an enemy army arrive and deny them the city. So an abandonment that is running stops by itself, at the next turn start, when:
- an enemy military unit comes within 6 tiles;
- the city is damaged or besieged;
- the city becomes your last city (for example you lost your other cities), so the removal can never eliminate you;
- the city is captured, flips, or changes hands in a trade.

There is no cooldown after an auto-cancel, so you can restart as soon as the problem clears (if the city is still yours). The loyalty penalty on your other cities keeps going for as many turns as the abandonment ran, the same as after a cancel. You get a notification with the reason.

## Notifications

- When you start, you get a notice with the turns left. You then get one every turn of the countdown, and another when the city is removed and when the penalty ends.
- Every player who has met you gets a notice when you start, cancel (or an auto-cancel stops it) and when the city is removed. Their notice does not say how many turns are left. It carries a map location only if they have already revealed the city's tile.
- If the city is captured or flips during the countdown, you and the players who have met you are told.

## Edge cases

- If growth pushes the population above the schedule, it is cut back at the next turn start. If the city is already smaller, it is not touched.
- Barbarian and Free City units near your city block a new abandonment and cancel a running one, even though you are not "at war" with them in the usual sense.

## Compatibility

- Requires Gathering Storm.
- Tested in multiplayer.
- The mod adds a button to the city panel. Mods that rework that panel's buttons may move or hide it. Not tested with any.
- It is saved with your game. Turn it on before you start a game, and don't remove it in the middle of one.

## Install

- **Steam Workshop:** subscribe at the link above, then enable **Abandon Cities** in Additional Content > Mods and start a new game.
- **Manual:** download `AbandonCities_1.0.0.zip` from the [GitHub release](https://github.com/ThePotatoTurtle/civ6-abandon-city/releases) and unzip the mod folder into your Civilization VI `Mods` folder, so the folder with the `.modinfo` file sits directly inside `Mods`. That folder is usually `Documents\My Games\Sid Meier's Civilization VI\Mods` (it may be under OneDrive). Then enable the mod in Additional Content > Mods and start a new game.

## Known limitations

- The AI never abandons cities.
- The penalty shows in the city's loyalty breakdown as "Other effects", not under its own name.

## Changelog

- 1.0.0: First release.

By ThePotatoTurtle.
