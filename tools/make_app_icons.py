#!/usr/bin/env python3
"""Generate CREG's Icon Composer app icons.

The mark is an M built from two glass towers beside a Q drawn as a three-segment
donut chart with a chat tail: commercial real estate, queried by conversation.

Geometry lives here once and every palette is emitted from it, so the three
variants cannot drift apart. Output is pure text (SVG + JSON) with no third-party
dependencies; render and inspect the result with Icon Composer's `ictool`.

    python3 tools/make_app_icons.py
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

# Icon Composer authors on a 1024pt canvas. Keeping art inside the inset avoids
# the corners the squircle mask and the glass edge eat into.
CANVAS = 1024

# --- Lockup geometry -------------------------------------------------------
# The M: two tower slabs as the outer stems, a chevron between them.
TOWER_TOP = 275.0
TOWER_BOTTOM = 735.0
TOWER_WIDTH = 90.0
LEFT_TOWER_X = 145.0
RIGHT_TOWER_X = 445.0
# The narrow lit face that turns each slab from a rectangle into a building.
SIDE_FACE_WIDTH = 20.0
# A crisp light frame around each slab; without it the towers lose their edges
# once the system's glass pass washes the interior out.
TOWER_FRAME = 5.0

# The chevron is stroked rather than outlined so the apex miters cleanly.
CHEVRON_APEX_X = (LEFT_TOWER_X + TOWER_WIDTH + RIGHT_TOWER_X) / 2.0
CHEVRON_APEX_Y = 620.0
CHEVRON_WIDTH = 74.0

PLINTH_Y = 741.0
PLINTH_HEIGHT = 14.0

# The Q: a true circle, so equal radii, with three 120-degree segments.
Q_CENTER = (720.0, 520.0)
Q_OUTER_R = 160.0
Q_INNER_R = 92.0
Q_SEGMENT_GAP_DEG = 4.0
Q_STROKE = 11.0
# The chat tail, as a rounded tab off the lower right.
TAIL_START_DEG = 22.0
TAIL_END_DEG = 70.0
TAIL_TIP_DEG = 46.0
TAIL_TIP_REACH = 78.0
TAIL_BULGE = 46.0

WINDOW_COLS = 4
WINDOW_ROWS = 12
WINDOW_INSET = 9.0
WINDOW_GAP_X = 6.0
WINDOW_GAP_Y = 10.0

GLASS_LIGHT = "#EEF4FF"
GLASS_MID = "#C3D7F2"
GLASS_EDGE = "#AFCBEC"
# The towers are night glass: a deep face so the lit windows carry the contrast.
TOWER_FACE = "#2F5686"
TOWER_SIDE = "#42709F"
WINDOW_COOL = "#E4F0FD"
WINDOW_WARM = "#FFCE85"


@dataclass(frozen=True)
class Palette:
    """One shippable icon: a ground gradient and the Q's three segments."""

    name: str
    ground_top: str
    ground_bottom: str
    segments: tuple[str, str, str]


# Three segments need three separable hues, and the brand only supplies two, so
# each palette contributes its own third rather than a near-duplicate tint.
PALETTES = (
    # Reference image 1: near-black navy, brand turquoise and blue.
    Palette(
        name="AppIconMidnight",
        ground_top="#16304F",
        ground_bottom="#060D1C",
        segments=("#33B5D1", "#1F70ED", "#8E7BF5"),
    ),
    # Reference image 2: indigo ground, gold third.
    Palette(
        name="AppIconIndigo",
        ground_top="#3A3A80",
        ground_bottom="#1A1A45",
        segments=("#1F70ED", "#2FD9C0", "#E8B93B"),
    ),
    # Image 1's ground with image 2's gold.
    Palette(
        name="AppIconMidnightGold",
        ground_top="#16304F",
        ground_bottom="#060D1C",
        segments=("#33B5D1", "#1F70ED", "#E8B93B"),
    ),
)


def hex_to_extended_srgb(value: str) -> str:
    """icon.json wants components as `extended-srgb:r,g,b,a` in 0...1."""
    value = value.lstrip("#")
    r, g, b = (int(value[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def window_mix(col: int, row: int) -> tuple[str, float]:
    """Deterministic lit-window pattern.

    A hash rather than `random` keeps regeneration byte-identical without
    depending on seeding behaviour. Opacities stay high because the system's
    glass pass flattens whatever contrast the artwork ships with.
    """
    noise = ((col * 73856093) ^ (row * 19349663)) % 1000 / 1000.0
    if noise < 0.16:
        return WINDOW_WARM, 0.98
    if noise < 0.26:
        return WINDOW_WARM, 0.72
    return WINDOW_COOL, 0.62 + 0.36 * noise


def svg_document(body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" '
        f'height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">\n{body}</svg>\n'
    )


def tower(x: float, mirrored: bool) -> str:
    """One glass slab: a narrow bright face, a broad windowed face, a plinth."""
    parts: list[str] = []
    height = TOWER_BOTTOM - TOWER_TOP
    if mirrored:
        side_x = x + TOWER_WIDTH - SIDE_FACE_WIDTH
        face_x = x
    else:
        side_x = x
        face_x = x + SIDE_FACE_WIDTH
    face_width = TOWER_WIDTH - SIDE_FACE_WIDTH

    parts.append(
        f'  <rect x="{face_x:.1f}" y="{TOWER_TOP:.1f}" width="{face_width:.1f}" '
        f'height="{height:.1f}" fill="{TOWER_FACE}"/>'
    )
    parts.append(
        f'  <rect x="{side_x:.1f}" y="{TOWER_TOP:.1f}" width="{SIDE_FACE_WIDTH:.1f}" '
        f'height="{height:.1f}" fill="{TOWER_SIDE}"/>'
    )
    # The frame is what keeps the slab reading as a building at 60px.
    parts.append(
        f'  <rect x="{x + TOWER_FRAME / 2:.1f}" y="{TOWER_TOP + TOWER_FRAME / 2:.1f}" '
        f'width="{TOWER_WIDTH - TOWER_FRAME:.1f}" height="{height - TOWER_FRAME:.1f}" '
        f'fill="none" stroke="{GLASS_LIGHT}" stroke-width="{TOWER_FRAME:.1f}"/>'
    )
    divider_x = side_x + SIDE_FACE_WIDTH if not mirrored else side_x
    parts.append(
        f'  <rect x="{divider_x - TOWER_FRAME / 2:.1f}" y="{TOWER_TOP:.1f}" '
        f'width="{TOWER_FRAME:.1f}" height="{height:.1f}" fill="{GLASS_LIGHT}"/>'
    )

    inner_x = face_x + WINDOW_INSET
    inner_w = face_width - 2 * WINDOW_INSET
    inner_y = TOWER_TOP + WINDOW_INSET
    inner_h = height - 2 * WINDOW_INSET
    win_w = (inner_w - (WINDOW_COLS - 1) * WINDOW_GAP_X) / WINDOW_COLS
    win_h = (inner_h - (WINDOW_ROWS - 1) * WINDOW_GAP_Y) / WINDOW_ROWS

    for row in range(WINDOW_ROWS):
        for col in range(WINDOW_COLS):
            # Mirror the pattern so the two towers are not identical twins.
            key_col = col + (100 if mirrored else 0)
            fill, opacity = window_mix(key_col, row)
            wx = inner_x + col * (win_w + WINDOW_GAP_X)
            wy = inner_y + row * (win_h + WINDOW_GAP_Y)
            parts.append(
                f'  <rect x="{wx:.1f}" y="{wy:.1f}" width="{win_w:.1f}" '
                f'height="{win_h:.1f}" fill="{fill}" opacity="{opacity:.2f}"/>'
            )
    return "\n".join(parts)


def towers_svg() -> str:
    body = [tower(LEFT_TOWER_X, mirrored=False), tower(RIGHT_TOWER_X, mirrored=True)]
    plinth_x = LEFT_TOWER_X - 15.0
    plinth_w = (RIGHT_TOWER_X + TOWER_WIDTH + 15.0) - plinth_x
    body.append(
        f'  <rect x="{plinth_x:.1f}" y="{PLINTH_Y:.1f}" width="{plinth_w:.1f}" '
        f'height="{PLINTH_HEIGHT:.1f}" rx="{PLINTH_HEIGHT / 2:.1f}" fill="{GLASS_EDGE}"/>'
    )
    return svg_document("\n".join(body) + "\n")


def chevron_svg() -> str:
    """The M's middle V.

    Drawn as one mitered stroke, then the right arm is restroked darker so the
    apex reads as a fold rather than a flat wedge.
    """
    left_x = LEFT_TOWER_X + TOWER_WIDTH
    right_x = RIGHT_TOWER_X
    full = (
        f'  <path d="M {left_x:.1f},{TOWER_TOP:.1f} '
        f'L {CHEVRON_APEX_X:.1f},{CHEVRON_APEX_Y:.1f} '
        f'L {right_x:.1f},{TOWER_TOP:.1f}" fill="none" stroke="{GLASS_LIGHT}" '
        f'stroke-width="{CHEVRON_WIDTH:.1f}" stroke-linejoin="miter" '
        f'stroke-miterlimit="12"/>'
    )
    right_arm = (
        f'  <path d="M {CHEVRON_APEX_X:.1f},{CHEVRON_APEX_Y:.1f} '
        f'L {right_x:.1f},{TOWER_TOP:.1f}" fill="none" stroke="{GLASS_MID}" '
        f'stroke-width="{CHEVRON_WIDTH:.1f}" stroke-linecap="butt"/>'
    )
    return svg_document(full + "\n" + right_arm + "\n")


def polar(angle_deg: float, radius: float) -> tuple[float, float]:
    rad = math.radians(angle_deg)
    return (
        Q_CENTER[0] + radius * math.cos(rad),
        Q_CENTER[1] + radius * math.sin(rad),
    )


def annular_sector(start_deg: float, end_deg: float, fill: str) -> str:
    large = 1 if (end_deg - start_deg) % 360 > 180 else 0
    ox1, oy1 = polar(start_deg, Q_OUTER_R)
    ox2, oy2 = polar(end_deg, Q_OUTER_R)
    ix2, iy2 = polar(end_deg, Q_INNER_R)
    ix1, iy1 = polar(start_deg, Q_INNER_R)
    return (
        f'  <path d="M {ox1:.2f},{oy1:.2f} '
        f'A {Q_OUTER_R:.1f},{Q_OUTER_R:.1f} 0 {large},1 {ox2:.2f},{oy2:.2f} '
        f'L {ix2:.2f},{iy2:.2f} '
        f'A {Q_INNER_R:.1f},{Q_INNER_R:.1f} 0 {large},0 {ix1:.2f},{iy1:.2f} Z" '
        f'fill="{fill}"/>'
    )


def query_svg(segments: tuple[str, str, str]) -> str:
    parts: list[str] = []
    half_gap = Q_SEGMENT_GAP_DEG / 2.0
    for index, color in enumerate(segments):
        start = -90.0 + index * 120.0 + half_gap
        end = -90.0 + (index + 1) * 120.0 - half_gap
        parts.append(annular_sector(start, end, color))

    # One closed outline carrying both the circle and the chat tail. Left
    # unfilled so the ground shows through the tail, as in the references. The
    # arc runs the long way round, so the two curves out to the tip are the only
    # thing closing the path -- no chord is ever drawn across the donut.
    sx, sy = polar(TAIL_START_DEG, Q_OUTER_R)
    ex, ey = polar(TAIL_END_DEG, Q_OUTER_R)
    tx, ty = polar(TAIL_TIP_DEG, Q_OUTER_R + TAIL_TIP_REACH)
    c1x, c1y = polar(TAIL_START_DEG + 5.0, Q_OUTER_R + TAIL_BULGE)
    c2x, c2y = polar(TAIL_END_DEG - 5.0, Q_OUTER_R + TAIL_BULGE)
    parts.append(
        f'  <path d="M {ex:.2f},{ey:.2f} '
        f'A {Q_OUTER_R:.1f},{Q_OUTER_R:.1f} 0 1,1 {sx:.2f},{sy:.2f} '
        f'Q {c1x:.2f},{c1y:.2f} {tx:.2f},{ty:.2f} '
        f'Q {c2x:.2f},{c2y:.2f} {ex:.2f},{ey:.2f} Z" fill="none" '
        f'stroke="{GLASS_EDGE}" stroke-width="{Q_STROKE:.1f}" '
        f'stroke-linejoin="round"/>'
    )
    parts.append(
        f'  <circle cx="{Q_CENTER[0]:.1f}" cy="{Q_CENTER[1]:.1f}" '
        f'r="{Q_INNER_R:.1f}" fill="none" stroke="{GLASS_EDGE}" '
        f'stroke-width="{Q_STROKE:.1f}"/>'
    )
    return svg_document("\n".join(parts) + "\n")


def icon_json(palette: Palette) -> dict:
    """The ground lives in the document fill, not a layer.

    That is what lets the Clear and Tinted renditions strip it and keep only
    the mark.
    """
    return {
        "fill": {
            "linear-gradient": [
                hex_to_extended_srgb(palette.ground_top),
                hex_to_extended_srgb(palette.ground_bottom),
            ]
        },
        "groups": [
            {
                "layers": [
                    {"image-name": "towers.svg", "name": "Towers"},
                    {"image-name": "chevron.svg", "name": "Chevron"},
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "specular": True,
            },
            {
                "layers": [{"image-name": "query.svg", "name": "Query"}],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "specular": True,
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": ["macOS"]},
    }


def write_icon(destination: Path, palette: Palette) -> None:
    assets = destination / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "towers.svg").write_text(towers_svg())
    (assets / "chevron.svg").write_text(chevron_svg())
    (assets / "query.svg").write_text(query_svg(palette.segments))
    (destination / "icon.json").write_text(
        json.dumps(icon_json(palette), indent=2) + "\n"
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent / "CREG"
    for palette in PALETTES:
        target = root / f"{palette.name}.icon"
        write_icon(target, palette)
        print(f"wrote {target}")


if __name__ == "__main__":
    main()
