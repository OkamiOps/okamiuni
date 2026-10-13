#!/usr/bin/env python3
"""Gera/atualiza appcast.xml (Sparkle 2) para o OkamiUNI.

Só biblioteca padrão. Roda com `python3 -I Tools/appcast.py ...`.

Lê os textos de release de CHANGELOG.md (en) e CHANGELOG.pt-BR.md (pt-BR) para
a versão pedida, monta um <item> Sparkle com as duas <description> (CDATA em
HTML), o <enclosure> com assinatura EdDSA e tamanho, e insere esse item num
appcast.xml existente — substituindo um item da mesma versão, se houver, e
preservando os demais. Se o appcast de entrada não existir, começa vazio.

Uso típico (chamado por Tools/publicar-release.sh):

    python3 -I Tools/appcast.py \\
        --version 0.5.5 --build 10 \\
        --zip /tmp/OkamiUNI-0.5.5.zip \\
        --signature "..." \\
        --appcast appcast.xml

Ver `--help` para todas as opções.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sys
from email.utils import formatdate
from typing import Optional

CHANNEL_TITLE = "OkamiUNI"
CHANNEL_LINK = "https://okamiops.github.io/okamiuni/appcast.xml"
CHANNEL_DESCRIPTION = "Atualizações do OkamiUNI"
REPO = "OkamiOps/okamiuni"

RSS_NAMESPACES = (
    'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/"'
)

ITEM_RE = re.compile(r"[ \t]*<item>.*?</item>\s*", re.DOTALL)
VERSION_IN_ITEM_RE = re.compile(
    r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>"
)


# --------------------------------------------------------------------------
# Changelog extraction
# --------------------------------------------------------------------------


def extract_changelog_bullets(changelog_text: str, version: str) -> list[str]:
    """Devolve as linhas de bullet (sem o `- ` inicial) da seção `## {version} — ...`.

    A seção termina no próximo cabeçalho `## ` (qualquer nível igual) ou no
    fim do arquivo. Levanta ValueError se a seção não existir.
    """
    header_re = re.compile(
        r"^##[ \t]+" + re.escape(version) + r"[ \t]+—.*$",
        re.MULTILINE,
    )
    match = header_re.search(changelog_text)
    if not match:
        raise ValueError(
            f"Não encontrei a seção '## {version} — ...' no changelog."
        )

    body_start = match.end()
    next_header = re.search(r"^##[ \t]+", changelog_text[body_start:], re.MULTILINE)
    body_end = body_start + next_header.start() if next_header else len(changelog_text)
    body = changelog_text[body_start:body_end]

    bullets = []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("- "):
            bullets.append(stripped[2:].strip())
    return bullets


# --------------------------------------------------------------------------
# Markdown (inline) -> HTML
# --------------------------------------------------------------------------

_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_CODE_RE = re.compile(r"`([^`]+)`")


def markdown_inline_to_html(text: str) -> str:
    """Converte **bold**, `code` e [texto](url) em HTML, escapando o resto."""
    escaped = html.escape(text, quote=False)
    escaped = _LINK_RE.sub(r'<a href="\2">\1</a>', escaped)
    escaped = _BOLD_RE.sub(r"<strong>\1</strong>", escaped)
    escaped = _CODE_RE.sub(r"<code>\1</code>", escaped)
    return escaped


def bullets_to_html_list(bullets: list[str]) -> str:
    items = "".join(f"<li>{markdown_inline_to_html(b)}</li>" for b in bullets)
    return f"<ul>{items}</ul>"


# --------------------------------------------------------------------------
# project.yml (deploymentTarget.macOS)
# --------------------------------------------------------------------------


def read_min_system_version(project_yml_text: str) -> Optional[str]:
    match = re.search(
        r"deploymentTarget:\s*\n\s*macOS:\s*\"?([0-9][0-9.]*)\"?",
        project_yml_text,
    )
    return match.group(1) if match else None


# --------------------------------------------------------------------------
# Item / appcast assembly
# --------------------------------------------------------------------------


def rfc822_now() -> str:
    return formatdate(usegmt=True)


def xml_escape_attr(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_item_xml(
    *,
    version: str,
    build: str,
    url: str,
    length: int,
    signature: str,
    release_page_url: str,
    min_system_version: str,
    pub_date: str,
    bullets_en: list[str],
    bullets_pt: list[str],
) -> str:
    html_pt = bullets_to_html_list(bullets_pt) if bullets_pt else "<ul></ul>"
    html_en = bullets_to_html_list(bullets_en) if bullets_en else "<ul></ul>"

    return (
        "    <item>\n"
        f"      <title>Version {xml_escape_attr(version)}</title>\n"
        f"      <pubDate>{xml_escape_attr(pub_date)}</pubDate>\n"
        f"      <sparkle:fullReleaseNotesLink>{xml_escape_attr(release_page_url)}"
        "</sparkle:fullReleaseNotesLink>\n"
        f"      <sparkle:version>{xml_escape_attr(build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{xml_escape_attr(version)}"
        "</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{xml_escape_attr(min_system_version)}"
        "</sparkle:minimumSystemVersion>\n"
        f'      <description xml:lang="pt-BR"><![CDATA[{html_pt}]]></description>\n'
        f'      <description xml:lang="en"><![CDATA[{html_en}]]></description>\n'
        f'      <enclosure url="{xml_escape_attr(url)}" length="{int(length)}" '
        'type="application/octet-stream" '
        f'sparkle:edSignature="{xml_escape_attr(signature)}" />\n'
        "    </item>\n"
    )


def extract_existing_items(xml_text: Optional[str]) -> list[str]:
    if not xml_text:
        return []
    return ITEM_RE.findall(xml_text)


def item_version(item_xml: str) -> Optional[str]:
    match = VERSION_IN_ITEM_RE.search(item_xml)
    return match.group(1) if match else None


def build_appcast_xml(
    existing_xml: Optional[str],
    new_item_xml: str,
    new_version: str,
    *,
    channel_title: str = CHANNEL_TITLE,
    channel_link: str = CHANNEL_LINK,
    channel_description: str = CHANNEL_DESCRIPTION,
) -> str:
    """Monta o appcast.xml completo com `new_item_xml` prependado.

    Qualquer item existente com a mesma `sparkle:shortVersionString` de
    `new_version` é substituído; os demais são preservados, na ordem em que
    apareciam.
    """
    older_items = [
        item for item in extract_existing_items(existing_xml) if item_version(item) != new_version
    ]

    items_block = new_item_xml.rstrip("\n") + "\n"
    for item in older_items:
        items_block += item.rstrip() + "\n"

    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f"<rss {RSS_NAMESPACES} version=\"2.0\">\n"
        "  <channel>\n"
        f"    <title>{xml_escape_attr(channel_title)}</title>\n"
        f"    <link>{xml_escape_attr(channel_link)}</link>\n"
        f"    <description>{xml_escape_attr(channel_description)}</description>\n"
        "    <language>pt-BR</language>\n"
        f"{items_block}"
        "  </channel>\n"
        "</rss>\n"
    )


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Gera/atualiza o appcast.xml (Sparkle 2) do OkamiUNI."
    )
    parser.add_argument("--version", required=True, help="Ex.: 0.5.5")
    parser.add_argument("--build", required=True, help="CURRENT_PROJECT_VERSION, ex.: 10")
    parser.add_argument("--zip", help="Caminho do .zip final (usado para calcular o length)")
    parser.add_argument("--length", type=int, help="Tamanho do .zip em bytes (sobrepõe --zip)")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature (saída do sign_update)")
    parser.add_argument("--url", help="URL de download do .zip (default: release do GitHub)")
    parser.add_argument(
        "--release-page-url",
        help="URL da página de release (default: tag do GitHub)",
    )
    parser.add_argument(
        "--min-system-version",
        help="sparkle:minimumSystemVersion (default: lido de --project-yml)",
    )
    parser.add_argument("--pub-date", help="RFC 822 (default: agora)")
    parser.add_argument(
        "--appcast",
        default="appcast.xml",
        help="appcast.xml existente a atualizar (default: appcast.xml). "
        "Se não existir, começa vazio.",
    )
    parser.add_argument(
        "--output",
        help="Onde escrever o resultado (default: o mesmo caminho de --appcast)",
    )
    parser.add_argument("--changelog", default="CHANGELOG.md", help="Changelog em inglês")
    parser.add_argument(
        "--changelog-pt-br", default="CHANGELOG.pt-BR.md", help="Changelog em português"
    )
    parser.add_argument("--project-yml", default="project.yml")
    parser.add_argument("--repo", default=REPO, help="owner/repo do GitHub")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.length is not None:
        length = args.length
    elif args.zip:
        length = os.path.getsize(args.zip)
    else:
        print("▸ ERRO: informe --zip ou --length para calcular o tamanho do enclosure", file=sys.stderr)
        return 1

    url = args.url or (
        f"https://github.com/{args.repo}/releases/download/v{args.version}/"
        f"OkamiUNI-{args.version}.zip"
    )
    release_page_url = args.release_page_url or (
        f"https://github.com/{args.repo}/releases/tag/v{args.version}"
    )

    min_system_version = args.min_system_version
    if not min_system_version:
        try:
            with open(args.project_yml, "r", encoding="utf-8") as fh:
                min_system_version = read_min_system_version(fh.read())
        except FileNotFoundError:
            min_system_version = None
        if not min_system_version:
            print(
                "▸ ERRO: não achei deploymentTarget.macOS em "
                f"{args.project_yml!r}; informe --min-system-version",
                file=sys.stderr,
            )
            return 1

    try:
        with open(args.changelog, "r", encoding="utf-8") as fh:
            bullets_en = extract_changelog_bullets(fh.read(), args.version)
    except (FileNotFoundError, ValueError) as exc:
        print(f"▸ ERRO lendo {args.changelog!r}: {exc}", file=sys.stderr)
        return 1

    try:
        with open(args.changelog_pt_br, "r", encoding="utf-8") as fh:
            bullets_pt = extract_changelog_bullets(fh.read(), args.version)
    except (FileNotFoundError, ValueError) as exc:
        print(f"▸ ERRO lendo {args.changelog_pt_br!r}: {exc}", file=sys.stderr)
        return 1

    pub_date = args.pub_date or rfc822_now()

    item_xml = build_item_xml(
        version=args.version,
        build=args.build,
        url=url,
        length=length,
        signature=args.signature,
        release_page_url=release_page_url,
        min_system_version=min_system_version,
        pub_date=pub_date,
        bullets_en=bullets_en,
        bullets_pt=bullets_pt,
    )

    existing_xml = None
    if os.path.exists(args.appcast):
        with open(args.appcast, "r", encoding="utf-8") as fh:
            existing_xml = fh.read()

    full_xml = build_appcast_xml(existing_xml, item_xml, args.version)

    output_path = args.output or args.appcast
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        fh.write(full_xml)

    print(f"▸ appcast gravado em {output_path} (item da versão {args.version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
