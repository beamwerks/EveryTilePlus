# EveryTile +

A Garmin Connect IQ **data field** for Edge cycling computers that tracks
"explorer tiles" — the OpenStreetMap-style zoom‑14 map tiles you ride through.

While recording an activity, the field shows a 5×5 grid of tiles centred on your
current position:

- **red** — tile never visited
- **green** — tile visited on a previous ride
- **bright green** — tile entered during the current ride

It also overlays your track and a heading arrow, and shows running counts of new
tiles (all‑time) and tiles crossed this ride. You can pre‑load the tiles you've
already ridden via a settings string (see below).

## Attribution & license

EveryTile + is a fork of **[EveryTile](https://github.com/to-ko/EveryTile)** by
Tomasz Korzec, extended to support newer Edge devices and ongoing improvements.
Like the original, it is licensed under the **GNU General Public License v3** —
see [`COPYING`](COPYING). Source for this build is published in this repository
to satisfy the GPL.

## Supported devices

Edge 540, 550, 840, 850, 1040, 1050, Explore 2, and Edge MTB. (`minApiLevel`
4.0.0.)

## Building

Requires the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) and
a developer key.

```sh
monkeyc -d edge840 -f monkey.jungle -o bin/EveryTilePlus.prg -y /path/to/developer_key
monkeydo bin/EveryTilePlus.prg edge840   # run in the simulator
```

Most development is done with the VS Code **Monkey C** extension. Each device
maps to one hard‑coded screen layout via per‑product `excludeAnnotations` in
`monkey.jungle`, so rebuild every device after changing layout code.

## Settings

- **Home Latitude / Longitude** — centre of the persistent tile map.
- **Map string** — an optional encoded string of tiles you've already visited,
  so your history shows up immediately.
