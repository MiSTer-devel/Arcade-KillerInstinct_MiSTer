#!/usr/bin/env python3
"""Build the packed DCS sound-ROM image the simulation benches expect.

The eight 512 KiB DCS devices are concatenated into one 4 MiB image. The order
is not a guess: MAME's ``kinst`` dcs region places them at 2 MiB intervals, and
that offset divided by 0x200000 is the ROM-select index dcs_mem decodes from
rom_addr[22:20].

dcs_mem models the board's sparse map itself - a 1 MiB gap reading 0xFF after
each 512 KiB device, which in our word-addressed space is rom_addr[19] - so the
image handed to it is simply the devices packed back to back with no holes.

The image is game data and is deliberately not committed. Build it on demand:

    python tools/build_dcs_rom.py --zip "<path>/games/kinst.zip" --out <dir>

which writes kinst_dcs.bin (4 MiB, for tb_ki_dcs_realrom via +ROM=) plus
u2..u5.bin (1 MiB each, the split dcs_mem's own $fread loader wants when
EXT_ROM is 0).
"""

import argparse
import os
import zipfile

# MAME kinst dcs region: u10-l1 @0x000000, u11-l1 @0x200000, u12-l1 @0x400000,
# u13-l1 @0x600000, u33-l1 @0x800000, u34-l1 @0xa00000, u35-l1 @0xc00000,
# u36-l1 @0xe00000.
ORDER = ["u10-l1", "u11-l1", "u12-l1", "u13-l1",
         "u33-l1", "u34-l1", "u35-l1", "u36-l1"]

DEVICE_BYTES = 0x80000        # 512 KiB per device
PACKED_BYTES = DEVICE_BYTES * len(ORDER)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", required=True, help="path to kinst.zip")
    ap.add_argument("--out", required=True, help="directory to write the images into")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    with zipfile.ZipFile(args.zip) as z:
        names = set(z.namelist())
        missing = [n for n in ORDER if n not in names]
        if missing:
            raise SystemExit("kinst.zip is missing DCS ROMs: %s" % ", ".join(missing))
        parts = []
        for name in ORDER:
            data = z.read(name)
            if len(data) != DEVICE_BYTES:
                raise SystemExit("%s is %d bytes, expected %d"
                                 % (name, len(data), DEVICE_BYTES))
            parts.append(data)

    blob = b"".join(parts)
    assert len(blob) == PACKED_BYTES

    # ROM 0 opens with a boot header and then the ASCII title. Checking it here
    # turns a silently mis-ordered image into an immediate, obvious failure
    # rather than a core that boots into nonsense.
    title = blob[4:16].decode("ascii", errors="replace")
    if not title.startswith("Killer"):
        raise SystemExit("ROM 0 does not begin with the expected title (saw %r); "
                         "the packing order is probably wrong" % title)

    packed = os.path.join(args.out, "kinst_dcs.bin")
    with open(packed, "wb") as f:
        f.write(blob)
    print("wrote %s (%d bytes)" % (packed, len(blob)))

    for i in range(4):
        chunk = blob[i * 0x100000:(i + 1) * 0x100000]
        path = os.path.join(args.out, "u%d.bin" % (i + 2))
        with open(path, "wb") as f:
            f.write(chunk)
        print("wrote %s (%d bytes)" % (path, len(chunk)))

    print("ROM 0 header %s, title %r" % (" ".join("%02x" % b for b in blob[:4]), title))


if __name__ == "__main__":
    main()
