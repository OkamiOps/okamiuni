#!/usr/bin/env python3
"""Audita os papéis semânticos dos temas antes de gerar o catálogo Swift.

Uso:
    python3 Tools/audit_theme_contrast.py

O script lê apenas ``design/tokens.json``. Ele separa mínimos funcionais de
texto/foco dos contratos visuais de superfícies e hairlines. Divisórias
decorativas não são tratadas como contornos de controle: nos temas escuros elas
devem permanecer presentes, porém suaves.
"""

from __future__ import annotations

import json
import pathlib
import sys

from generate_themes import parse_color


ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKENS = ROOT / "design" / "tokens.json"
DARK = {
    "noite", "grafite", "okami", "vapor", "neon", "sinal", "blackbox",
    "magenta", "neural", "corsa", "brutalnoite", "contraste", "comando",
    "override",
}


def linear(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(css: str) -> float:
    red, green, blue, _ = parse_color(css)
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)


def contrast(foreground: str, background: str) -> float:
    lighter, darker = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def resolved(theme: dict[str, str], base: dict[str, str], key: str) -> str:
    if key in theme:
        return theme[key]
    return base[key]


def main() -> int:
    document = json.loads(TOKENS.read_text())
    base: dict[str, str] = document["base"]
    failures: list[str] = []

    print("tema          ink  ink2 ink3 ink4 ação foco acento borda botão linha fio  rail painel")
    for name, theme in document["themes"].items():
        surface = resolved(theme, base, "--surface")
        text_ratios = [
            contrast(resolved(theme, base, key), surface)
            for key in ("--ink", "--ink2", "--ink3", "--ink4")
        ]
        action = contrast(
            resolved(theme, base, "--on-accent"),
            resolved(theme, base, "--accent"),
        )
        focus = contrast(resolved(theme, base, "--accent"), surface)
        accent_text = contrast(
            resolved(theme, base, "--accent-ink"),
            resolved(theme, base, "--accent-soft"),
        )
        accent_border = contrast(
            resolved(theme, base, "--accent-line"),
            resolved(theme, base, "--accent-soft"),
        )
        button = contrast(
            resolved(theme, base, "--btn-line"),
            resolved(theme, base, "--btn"),
        )
        line = contrast(resolved(theme, base, "--line"), surface)
        detail = contrast(resolved(theme, base, "--line2"), surface)
        rail = contrast(resolved(theme, base, "--surface2"), surface)
        panel = contrast(resolved(theme, base, "--surface3"), surface)

        print(
            f"{name:13} "
            + " ".join(f"{ratio:4.2f}" for ratio in text_ratios)
            + f" {action:4.2f} {focus:4.2f} {accent_text:4.2f} {accent_border:4.2f}"
            + f" {button:4.2f} {line:4.2f} {detail:4.2f} {rail:4.2f} {panel:4.2f}"
        )

        for key, ratio in zip(("ink", "ink2", "ink3", "ink4"), text_ratios):
            if ratio < 4.5:
                failures.append(f"{name}: {key}/surface = {ratio:.2f}:1 (< 4.5:1)")
        if action < 4.5:
            failures.append(f"{name}: onAccent/accent = {action:.2f}:1 (< 4.5:1)")
        if focus < 3:
            failures.append(f"{name}: accent/surface = {focus:.2f}:1 (< 3:1)")
        if accent_text < 4.5:
            failures.append(f"{name}: accentInk/accentSoft = {accent_text:.2f}:1 (< 4.5:1)")
        if name in DARK and not 1.5 <= accent_border <= 2.5:
            failures.append(
                f"{name}: accentLine/accentSoft = {accent_border:.2f}:1 (fora de 1.5–2.5:1)"
            )
        if name in DARK and not 1.35 <= button <= 2.5:
            failures.append(f"{name}: btnLine/btn = {button:.2f}:1 (fora de 1.35–2.5:1)")
        if name in DARK and not 1.25 <= line <= 2:
            failures.append(f"{name}: line/surface = {line:.2f}:1 (fora de 1.25–2:1)")
        if name in DARK and not 1.08 <= detail <= 1.45:
            failures.append(f"{name}: line2/surface = {detail:.2f}:1 (fora de 1.08–1.45:1)")
        if name in DARK and line < detail + 0.08:
            failures.append(
                f"{name}: line ({line:.2f}:1) não se separa de line2 ({detail:.2f}:1)"
            )
        if name in DARK and not 1.08 <= rail <= 1.25:
            failures.append(f"{name}: surface2/surface = {rail:.2f}:1 (fora de 1.08–1.25:1)")
        if name in DARK and not 1.18 <= panel <= 1.45:
            failures.append(f"{name}: surface3/surface = {panel:.2f}:1 (fora de 1.18–1.45:1)")

    if failures:
        print("\nFalhas de contraste:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("\n26 temas aprovados nos contratos de contraste.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
