# Follower sprites — optional

**You don't need anything in here.** Followers hover, and a hovering follower
reads fine from a single 16×16 image — which the ROM already has for every
species in the form of the party-menu icon. All 151 are covered out of the box.

The catch is that icons are *archetypes*, not portraits: the whole Bulbasaur
line shows the GRASS icon, Gyarados shows SNAKE. If you want a species to look
like itself, drop art here and it takes priority over its icon.

Gen 1 has no walking overworld sprites for Pokémon — the ROM carries 73
character sheets (people, a bird, a boulder, Snorlax, a Seel) and, in Yellow
only, `SPRITE_PIKACHU`. That's why this is BYO rather than extracted.

Since followers hover, only the standing frames are ever drawn, pointed the
way the follower is drifting. A 16×96 sheet is still the format — the walk
frames simply go unused.

## The contract

One PNG per species, named for the species in lowercase with hyphens:

```
pikachu.png     charizard.png     mr-mime.png
nidoran-f.png   nidoran-m.png     farfetchd.png
```

Each file is **16 × 96** — six 16 × 16 frames stacked vertically:

| row | frame |
| --- | --- |
| 0 | stand down |
| 1 | stand up |
| 2 | stand left |
| 3 | walk down |
| 4 | walk up |
| 5 | walk left |

Right-facing frames are **not** in the sheet — the renderer produces them by
flipping the left-facing ones horizontally.

Near-white pixels (red channel above ~0.83) are keyed to transparent by the
renderer, which is why a white background disappears on its own. If your
source has real alpha instead, pass `--key-white` to the importer so those
pixels become white and get keyed the same way.

## Getting art in

```bash
python tools/import_follower_sprites.py --from ./raw --layout row6
```

`--layout` describes your *source* files: `row6` / `col6` for six frames in a
row or column, `row3` / `col3` when you only have the three standing poses
(the walk frames then reuse them — no animation, but always the right facing).

If your files are numbered rather than named, add `--by dex`.

To author one by hand:

```bash
python tools/import_follower_sprites.py --make-template template.png
```

To see what's installed and whether anything is the wrong size:

```bash
python tools/import_follower_sprites.py --check
```

## What happens with missing art

Nothing breaks. A species with no PNG here simply has no follower — that
ghost walks alone. You can supply one file or all 151.

## Licensing

Keep whatever you put here local. This folder is meant to be gitignored, the
same way the battle-art mod keeps its imported sprites out of version control.
Don't redistribute sprite rips with the mod.
