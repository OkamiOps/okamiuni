#!/usr/bin/env python3
"""Generates UNIDesign's theme catalogue from the canonical token data.

``design/tokens.json`` is the canonical structured source for colour values and
theme tokens, including the shared ``base`` fallbacks. The Claude Design HTML
in ``design/`` remains the visual reference and supplies the theme display
names and notes; it is not the structured source for colour values. Re-run
this whenever either source changes:

    python3 Tools/generate_themes.py

Reads:  design/tokens.json            (canonical structured token values and fallbacks)
        design/OkamiUNI*.dc.html      (visual reference, display names and notes)
Writes: Packages/UNIDesign/Sources/UNIDesign/Themes+Generated.swift
"""

from __future__ import annotations

import html
import math
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKENS = ROOT / "design" / "tokens.json"
OUT = ROOT / "Packages/UNIDesign/Sources/UNIDesign/Themes+Generated.swift"


def prototype_path() -> pathlib.Path:
    matches = sorted((ROOT / "design").glob("*.dc.html"))
    if not matches:
        sys.exit("no .dc.html prototype found in design/")
    return matches[0]


# --- parsing -----------------------------------------------------------------


def oklch_to_srgb(L: float, C: float, H: float) -> tuple[float, float, float]:
    """OKLCH -> OKLab -> linear sRGB -> gamma-encoded sRGB, clamped to gamut."""
    h = math.radians(H)
    a, b = C * math.cos(h), C * math.sin(h)

    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_**3, m_**3, s_**3

    lin = (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    )

    def encode(c: float) -> float:
        c = max(0.0, min(1.0, c))
        return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055

    return tuple(encode(c) for c in lin)  # type: ignore[return-value]


def parse_color(css: str) -> tuple[float, float, float, float]:
    s = css.strip()
    m = re.match(r"oklch\(\s*([\d.]+)%?\s+([\d.]+)\s+([\d.]+)\s*(?:/\s*([\d.]+))?\s*\)", s)
    if m:
        L = float(m.group(1))
        if "%" in s.split()[0]:
            L /= 100
        r, g, b = oklch_to_srgb(L, float(m.group(2)), float(m.group(3)))
        return r, g, b, float(m.group(4)) if m.group(4) else 1.0
    if s.startswith("#"):
        hexpart = s[1:]
        if len(hexpart) == 3:
            hexpart = "".join(c * 2 for c in hexpart)
        if len(hexpart) == 6:
            hexpart += "ff"
        if len(hexpart) != 8:
            raise ValueError(f"bad hex color: {css!r}")
        r, g, b, a = (int(hexpart[i : i + 2], 16) / 255 for i in (0, 2, 4, 6))
        return r, g, b, a
    m = re.match(r"rgba?\(([^)]*)\)", s)
    if not m:
        raise ValueError(f"bad color: {css!r}")
    parts = [p.strip() for p in m.group(1).split(",")]
    r, g, b = (float(parts[i]) / 255 for i in range(3))
    a = float(parts[3]) if len(parts) > 3 else 1.0
    return r, g, b, a


def swift_color(css: str) -> str:
    """Emits an exact literal.

    Hex and rgb() colours are byte values, so they are written as `n / 255`
    rather than a rounded decimal — that keeps them bit-identical to
    `TokenColor(css:)`, which the tests compare against. Only oklch, which has
    no byte form, falls back to full-precision decimals.
    """
    s = css.strip()

    if s.startswith("#"):
        hexpart = s[1:]
        if len(hexpart) == 3:
            hexpart = "".join(c * 2 for c in hexpart)
        if len(hexpart) == 6:
            hexpart += "ff"
        r, g, b, a = (int(hexpart[i : i + 2], 16) for i in (0, 2, 4, 6))
        alpha = "1" if a == 255 else f"{a} / 255"
        return f"TokenColor(red: {r} / 255, green: {g} / 255, blue: {b} / 255, opacity: {alpha})"

    m = re.match(r"rgba?\(([^)]*)\)", s)
    if m:
        parts = [p.strip() for p in m.group(1).split(",")]
        r, g, b = (int(round(float(parts[i]))) for i in range(3))
        a = parts[3] if len(parts) > 3 else "1"
        return f"TokenColor(red: {r} / 255, green: {g} / 255, blue: {b} / 255, opacity: {a})"

    r, g, b, a = parse_color(css)
    return f"TokenColor(red: {r!r}, green: {g!r}, blue: {b!r}, opacity: {a!r})"


def px(value: str) -> float:
    return float(re.sub(r"px$", "", value.strip()))


def parse_shadows(css: str) -> list[str]:
    """Splits a CSS box-shadow list on top-level commas, then parses each layer."""
    layers, depth, current = [], 0, ""
    for ch in css:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            layers.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        layers.append(current)

    out = []
    for layer in layers:
        layer = layer.strip()
        if not layer or layer == "none":
            continue
        color_match = re.search(r"(rgba?\([^)]*\)|#[0-9A-Fa-f]{3,8})", layer)
        if not color_match:
            raise ValueError(f"shadow layer without a color: {layer!r}")
        color = color_match.group(1)
        # `inset` muda a natureza da camada: brilho interno, não sombra externa.
        # Sem isto a camada saía como sombra e virava um anel em volta do botão.
        is_inset = "inset" in layer.split("(")[0]
        layer = layer.replace("inset", " ")
        # Lengths in order. A unitless `0` is valid CSS, so match the bare
        # number too — dropping it would shift x/y/blur by one position.
        lengths = [
            float(m.group(1))
            for m in re.finditer(r"(-?[\d.]+)(?:px)?(?=\s|$)", layer.replace(color, " "))
        ]
        if len(lengths) < 2:
            raise ValueError(f"shadow layer needs at least x and y: {layer!r}")
        while len(lengths) < 3:
            lengths.append(0.0)
        x, y, blur = lengths[0], lengths[1], lengths[2]
        spread = lengths[3] if len(lengths) > 3 else 0.0
        out.append(
            f"ShadowToken(x: {x}, y: {y}, blur: {blur}, spread: {spread}, "
            f"color: {swift_color(color)}"
            + (", isInset: true)" if is_inset else ")")
        )
    return out


FONT_MAP = {
    "newsreader": ("Newsreader", ".serif"),
    "space grotesk": ("Space Grotesk", ".default"),
    "inter tight": ("Inter Tight", ".default"),
    "inter": ("Inter", ".default"),
    "ibm plex mono": ("IBM Plex Mono", ".monospaced"),
    "jetbrains mono": ("JetBrains Mono", ".monospaced"),
}


def swift_font(css: str) -> str:
    first = css.split(",")[0].strip().strip("'\"").lower()
    if first.startswith("-apple-system"):
        return "FontFamily.system"
    # Longest key first so "inter tight" wins over "inter".
    for key in sorted(FONT_MAP, key=len, reverse=True):
        if first == key:
            name, design = FONT_MAP[key]
            return f'FontFamily(name: "{name}", design: {design})'
    if "mono" in first:
        return "FontFamily(name: nil, design: .monospaced)"
    if "serif" in first and "sans" not in first:
        return "FontFamily(name: nil, design: .serif)"
    return "FontFamily.system"


WEIGHTS = {
    "400": ".regular",
    "500": ".medium",
    "600": ".semibold",
    "650": ".semibold",
    "700": ".bold",
}


def swift_rowpad(css: str) -> str:
    parts = [px(p) for p in css.split()]
    if len(parts) == 1:
        t = r = b = l = parts[0]
    elif len(parts) == 2:
        t = b = parts[0]
        r = l = parts[1]
    elif len(parts) == 3:
        t, r, b = parts
        l = r
    else:
        t, r, b, l = parts[:4]
    return f"Insets(top: {t}, leading: {l}, bottom: {b}, trailing: {r})"


def luminance(css: str) -> float:
    r, g, b, _ = parse_color(css)

    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def read_catalogue(path: pathlib.Path) -> dict[str, dict[str, str]]:
    """Pulls id/name/note out of the prototype's THEMES array."""
    source = html.unescape(path.read_text(encoding="utf-8"))
    catalogue: dict[str, dict[str, str]] = {}
    pattern = re.compile(
        r"\{\s*id:\s*'([a-z]+)',\s*name:\s*'([^']*)',\s*note:\s*'([^']*)'"
    )
    for m in pattern.finditer(source):
        catalogue[m.group(1)] = {"name": m.group(2), "note": m.group(3)}
    return catalogue


# --- emit --------------------------------------------------------------------


def main() -> None:
    data = json.loads(TOKENS.read_text(encoding="utf-8"))
    base, themes = data["base"], data["themes"]
    catalogue = read_catalogue(prototype_path())

    missing = sorted(set(themes) - set(catalogue))
    if missing:
        print(f"warning: no display name for {', '.join(missing)}", file=sys.stderr)

    def token(theme_id: str, key: str) -> str:
        value = themes[theme_id].get(key, base.get(key))
        if value is None:
            raise KeyError(f"{theme_id} has no {key} and there is no base value")
        return value

    lines: list[str] = [
        "// Generated by Tools/generate_themes.py — do not edit by hand.",
        "// Source: design/tokens.json + the Claude Design prototype.",
        "",
        "import SwiftUI",
        "",
        "extension Theme {",
    ]

    ordered = list(themes)
    for theme_id in ordered:
        meta = catalogue.get(theme_id, {"name": theme_id.capitalize(), "note": ""})
        body_font = token(theme_id, "--body-font")
        body_case = ".sans" if "--sans" in body_font else ".serif"
        btn_shadow = parse_shadows(token(theme_id, "--btn-shadow"))
        shadow = parse_shadows(token(theme_id, "--shadow"))
        weight = WEIGHTS.get(token(theme_id, "--subj-weight").strip(), ".medium")
        is_dark = "true" if luminance(token(theme_id, "--paper")) < 0.4 else "false"

        prop = re.sub(r"[^a-z0-9]", "", theme_id)
        if meta["note"]:
            lines.append(f'    /// {meta["name"]} — {meta["note"]}')
        lines += [
            f"    public static let {prop} = Theme(",
            f'        id: "{theme_id}",',
            f'        name: "{meta["name"]}",',
            f'        note: "{meta["note"]}",',
            f"        isDark: {is_dark},",
        ]
        for swift_name, css_name in [
            ("paper", "--paper"), ("surface", "--surface"),
            ("surface2", "--surface2"), ("surface3", "--surface3"),
            ("ink", "--ink"), ("ink2", "--ink2"),
            ("ink3", "--ink3"), ("ink4", "--ink4"),
            ("line", "--line"), ("line2", "--line2"),
            ("accent", "--accent"), ("accentInk", "--accent-ink"),
            ("accentSoft", "--accent-soft"), ("accentLine", "--accent-line"),
            ("onAccent", "--on-accent"),
            ("btn", "--btn"), ("btnLine", "--btn-line"),
        ]:
            lines.append(f"        {swift_name}: {swift_color(token(theme_id, css_name))},")

        lines.append(f"        btnShadow: [{', '.join(btn_shadow)}],")
        lines.append(f"        shadow: [{', '.join(shadow)}],")
        lines.append(f"        serif: {swift_font(token(theme_id, '--serif'))},")
        lines.append(f"        sans: {swift_font(token(theme_id, '--sans'))},")
        lines.append(f"        mono: {swift_font(token(theme_id, '--mono'))},")
        lines.append(f"        bodyFont: {body_case},")
        lines.append(f"        radiusSmall: {px(token(theme_id, '--r2'))},")
        lines.append(f"        radiusLarge: {px(token(theme_id, '--r3'))},")
        lines.append(
            f"        capsTracking: {float(token(theme_id, '--caps').replace('em', ''))},"
        )
        lines.append(f"        rowPadding: {swift_rowpad(token(theme_id, '--rowpad'))},")
        lines.append(f"        subjectWeight: {weight},")
        lines.append(f"        subjectSize: {px(token(theme_id, '--subj-size'))}")
        lines += ["    )", ""]

    lines += [
        "    /// Every theme, in the order the design's picker shows them.",
        "    public static let all: [Theme] = [",
    ]
    for theme_id in ordered:
        lines.append(f"        .{re.sub(r'[^a-z0-9]', '', theme_id)},")
    lines += [
        "    ]",
        "",
        "    /// The design's default.",
        "    public static let `default` = Theme.tinta",
        "",
        "    public static func named(_ id: String) -> Theme? {",
        "        all.first { $0.id == id }",
        "    }",
        "}",
        "",
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} — {len(ordered)} themes")


if __name__ == "__main__":
    main()
