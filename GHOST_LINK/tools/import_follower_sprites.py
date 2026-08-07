#!/usr/bin/env python3
"""Turn a folder of overworld Pokemon sprites into GHOST LINK follower art.

Gen 1 has no walking overworld sprites for Pokemon, so followers are BYO. This
converts whatever you have into the one layout the engine reads.

TARGET FORMAT (src/render/SpriteRenderer.lua)
    A 16x96 PNG: six 16x16 frames stacked vertically, in this order

        0  stand down
        1  stand up
        2  stand left
        3  walk  down
        4  walk  up
        5  walk  left

    Right-facing frames are horizontal flips of the left ones, so they are not
    in the sheet. Near-white (red channel > 0.83) is keyed to transparent by
    the renderer, which is why a white background disappears on its own.

USAGE
    # a folder of per-species sheets, 6 frames left-to-right in one row
    python import_follower_sprites.py --from ./raw --layout row6

    # same, but the files are named 001.png, 002.png, ... by dex number
    python import_follower_sprites.py --from ./raw --layout row6 --by dex

    # only three frames available (stand down/up/left): walk frames reuse them
    python import_follower_sprites.py --from ./raw --layout row3

    # check what is already installed
    python import_follower_sprites.py --check

    # emit a labelled blank to author one by hand
    python import_follower_sprites.py --make-template mytemplate.png

Requires Pillow (pip install pillow).
"""

import argparse
import os
import re
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("This needs Pillow.  pip install pillow")

from dex_table import DEX

FRAME = 16
FRAMES = 6
SHEET = (FRAME, FRAME * FRAMES)

# Where the mod looks. Relative to the repo root (the folder holding GHOST_LINK).
DEFAULT_OUT = os.path.join("GHOST_LINK", "assets", "followers")

SPECIES = sorted(DEX.values())
BY_LOWER = {s.lower(): s for s in SPECIES}


def species_filename(species):
    """PIKACHU -> pikachu.png, MR_MIME -> mr-mime.png (matches the mod)."""
    return species.lower().replace("_", "-") + ".png"


def species_from_stem(stem, mode):
    """Resolve an input filename stem to a species key, or None."""
    stem = stem.strip()
    if mode == "dex":
        digits = re.match(r"^0*(\d{1,3})", stem)
        if not digits:
            return None
        return DEX.get(int(digits.group(1)))
    key = stem.lower().replace("-", "_").replace(" ", "_")
    # tolerate "025_pikachu" and "pikachu_walk"
    key = re.sub(r"^\d+[_-]*", "", key)
    key = re.sub(r"[_-]*(walk|overworld|ow|follower)$", "", key)
    if key in BY_LOWER:
        return BY_LOWER[key]
    return BY_LOWER.get(key.replace("_", ""), None)


def slice_frames(img, layout):
    """Cut the source into a list of frames, in engine order."""
    w, h = img.size

    if layout == "col6":
        n = 6
        fw, fh = w, h // n
        cells = [img.crop((0, i * fh, fw, (i + 1) * fh)) for i in range(n)]
        return cells

    if layout == "row6":
        n = 6
        fw, fh = w // n, h
        cells = [img.crop((i * fw, 0, (i + 1) * fw, fh)) for i in range(n)]
        return cells

    if layout in ("row3", "col3"):
        n = 3
        if layout == "row3":
            fw, fh = w // n, h
            cells = [img.crop((i * fw, 0, (i + 1) * fw, fh)) for i in range(n)]
        else:
            fw, fh = w, h // n
            cells = [img.crop((0, i * fh, fw, (i + 1) * fh)) for i in range(n)]
        # No walk frames supplied: reuse the standing pose. The sprite will not
        # animate, but it faces correctly and never shows a wrong frame.
        return cells + list(cells)

    raise ValueError("unknown layout " + layout)


def normalise(frame, key_white):
    """One frame -> 16x16 RGBA, nearest-neighbour so pixel art stays crisp."""
    frame = frame.convert("RGBA")
    if frame.size != (FRAME, FRAME):
        frame = frame.resize((FRAME, FRAME), Image.NEAREST)
    if key_white:
        # The renderer keys shade 0 by brightness, not by alpha, so a fully
        # transparent background must be made white for it to read as shade 0.
        px = frame.load()
        for y in range(FRAME):
            for x in range(FRAME):
                r, g, b, a = px[x, y]
                if a == 0:
                    px[x, y] = (255, 255, 255, 255)
    return frame


def build_sheet(src_path, layout, key_white):
    with Image.open(src_path) as img:
        frames = slice_frames(img, layout)
    sheet = Image.new("RGBA", SHEET, (255, 255, 255, 255))
    for i, frame in enumerate(frames[:FRAMES]):
        sheet.paste(normalise(frame, key_white), (0, i * FRAME))
    return sheet


def make_template(path):
    """A labelled blank, so hand-authoring does not need the docs open."""
    from PIL import ImageDraw
    scale = 8
    img = Image.new("RGBA", (FRAME * scale + 120, FRAME * FRAMES * scale), (255, 255, 255, 255))
    draw = ImageDraw.Draw(img)
    labels = ["stand down", "stand up", "stand left", "walk down", "walk up", "walk left"]
    for i, label in enumerate(labels):
        top = i * FRAME * scale
        draw.rectangle([0, top, FRAME * scale, top + FRAME * scale],
                       outline=(200, 0, 0, 255))
        draw.text((FRAME * scale + 8, top + FRAME * scale // 2 - 4), label, fill=(0, 0, 0, 255))
    img.save(path)
    print("wrote {} ({}x scale, {} frames)".format(path, scale, FRAMES))
    print("Author at 16x16 per cell; the red boxes are the frame bounds.")
    print("Delete the labels and boxes before saving the real sheet.")


def check(out_dir):
    have, missing = [], []
    for s in SPECIES:
        path = os.path.join(out_dir, species_filename(s))
        if os.path.exists(path):
            try:
                with Image.open(path) as im:
                    ok = im.size == SHEET
                have.append((s, ok, path))
            except Exception:
                have.append((s, False, path))
        else:
            missing.append(s)

    bad = [h for h in have if not h[1]]
    print("installed : {}/{}".format(len(have), len(SPECIES)))
    if bad:
        print("WRONG SIZE: {} (expected {}x{})".format(len(bad), SHEET[0], SHEET[1]))
        for s, _, path in bad[:10]:
            with Image.open(path) as im:
                print("   {:<12} {}x{}".format(s, im.size[0], im.size[1]))
    if missing:
        print("missing   : {} (these species just have no follower)".format(len(missing)))
        print("   " + ", ".join(missing[:12]) + (" ..." if len(missing) > 12 else ""))
    return 0 if not bad else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="src", help="folder of source sprites")
    ap.add_argument("--out", default=DEFAULT_OUT, help="output folder (default: %(default)s)")
    ap.add_argument("--layout", default="row6", choices=["row6", "col6", "row3", "col3"],
                    help="how frames are arranged in each source file")
    ap.add_argument("--by", default="name", choices=["name", "dex"],
                    help="resolve species from the filename by name or dex number")
    ap.add_argument("--key-white", action="store_true",
                    help="paint transparent pixels white so the renderer keys them out")
    ap.add_argument("--check", action="store_true", help="report what is installed and exit")
    ap.add_argument("--make-template", metavar="PATH", help="write an authoring template and exit")
    ap.add_argument("--dry-run", action="store_true", help="say what would happen, write nothing")
    args = ap.parse_args()

    if args.make_template:
        make_template(args.make_template)
        return 0

    if args.check:
        return check(args.out)

    if not args.src:
        ap.error("give --from <folder>, or --check, or --make-template")

    if not os.path.isdir(args.src):
        sys.exit("not a folder: " + args.src)

    if not args.dry_run:
        os.makedirs(args.out, exist_ok=True)

    written, skipped, unknown = 0, 0, []
    for entry in sorted(os.listdir(args.src)):
        stem, ext = os.path.splitext(entry)
        if ext.lower() not in (".png", ".gif", ".bmp"):
            continue
        species = species_from_stem(stem, args.by)
        if not species:
            unknown.append(entry)
            continue
        dest = os.path.join(args.out, species_filename(species))
        if args.dry_run:
            print("would write {:<14} <- {}".format(species_filename(species), entry))
            written += 1
            continue
        try:
            sheet = build_sheet(os.path.join(args.src, entry), args.layout, args.key_white)
            sheet.save(dest)
            written += 1
        except Exception as exc:
            print("skip {}: {}".format(entry, exc))
            skipped += 1

    print("")
    print("wrote   : {}".format(written))
    if skipped:
        print("failed  : {}".format(skipped))
    if unknown:
        print("unmatched filenames: {}".format(len(unknown)))
        print("   " + ", ".join(unknown[:8]) + (" ..." if len(unknown) > 8 else ""))
        print("   (try --by dex, or rename them to the species)")
    if not args.dry_run:
        print("")
        check(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
