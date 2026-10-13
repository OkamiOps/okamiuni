#!/usr/bin/env python3
"""Testes de Tools/appcast.py. Só biblioteca padrão.

Roda com (a partir da raiz do repo):

    python3 -I -m unittest tools.test_appcast
    # ou, com discover:
    python3 -I -m unittest discover -s tools -p 'test_*.py'
"""

from __future__ import annotations

import os
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import appcast  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

CHANGELOG_EN_FIXTURE = """\
# Changelog

## 0.5.5 — October 13

- First bullet with **bold** text.
- Second bullet with `inline code` and a [link](https://example.com/a&b).
- Third bullet with an ampersand & a < less-than.

## 0.5.4 — September 5

- Should not be picked up.
"""

CHANGELOG_PT_FIXTURE = """\
# Changelog

## 0.5.5 — 13 de outubro
- Primeiro item com **negrito**.
- Segundo item com `código` e um [link](https://example.com/a&b).

## 0.5.4 — 5 de setembro
- Não deve aparecer.
"""


class ChangelogExtractionTests(unittest.TestCase):
    def test_extracts_english_bullets(self):
        bullets = appcast.extract_changelog_bullets(CHANGELOG_EN_FIXTURE, "0.5.5")
        self.assertEqual(
            bullets,
            [
                "First bullet with **bold** text.",
                "Second bullet with `inline code` and a [link](https://example.com/a&b).",
                "Third bullet with an ampersand & a < less-than.",
            ],
        )

    def test_extracts_portuguese_bullets(self):
        bullets = appcast.extract_changelog_bullets(CHANGELOG_PT_FIXTURE, "0.5.5")
        self.assertEqual(
            bullets,
            [
                "Primeiro item com **negrito**.",
                "Segundo item com `código` e um [link](https://example.com/a&b).",
            ],
        )

    def test_stops_at_next_header_not_just_blank_line(self):
        bullets = appcast.extract_changelog_bullets(CHANGELOG_EN_FIXTURE, "0.5.4")
        self.assertEqual(bullets, ["Should not be picked up."])

    def test_missing_version_raises(self):
        with self.assertRaises(ValueError):
            appcast.extract_changelog_bullets(CHANGELOG_EN_FIXTURE, "9.9.9")

    def test_version_with_dots_does_not_match_substring(self):
        # "0.5.5" should not accidentally match a header for "0.5.50" etc.
        text = "## 0.5.50 — October 20\n- unrelated\n"
        with self.assertRaises(ValueError):
            appcast.extract_changelog_bullets(text, "0.5.5")

    def test_real_changelog_md_0_5_5_section(self):
        path = os.path.join(REPO_ROOT, "CHANGELOG.md")
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
        bullets = appcast.extract_changelog_bullets(content, "0.5.5")
        self.assertGreater(len(bullets), 0)
        joined = " ".join(bullets)
        self.assertIn("Google Calendar", joined)
        self.assertIn("build 10", joined)

    def test_real_changelog_pt_br_0_5_5_section(self):
        path = os.path.join(REPO_ROOT, "CHANGELOG.pt-BR.md")
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
        bullets = appcast.extract_changelog_bullets(content, "0.5.5")
        self.assertGreater(len(bullets), 0)
        joined = " ".join(bullets)
        self.assertIn("Google Agenda", joined)
        self.assertIn("build 10", joined)


class MarkdownInlineToHtmlTests(unittest.TestCase):
    def test_bold(self):
        self.assertEqual(
            appcast.markdown_inline_to_html("a **bold** word"),
            "a <strong>bold</strong> word",
        )

    def test_code(self):
        self.assertEqual(
            appcast.markdown_inline_to_html("a `code` word"),
            "a <code>code</code> word",
        )

    def test_link(self):
        self.assertEqual(
            appcast.markdown_inline_to_html("see [here](https://example.com/x)"),
            'see <a href="https://example.com/x">here</a>',
        )

    def test_escapes_ampersand_and_angle_brackets_outside_markdown(self):
        self.assertEqual(
            appcast.markdown_inline_to_html("a & b < c"),
            "a &amp; b &lt; c",
        )

    def test_escapes_ampersand_inside_link_url(self):
        html = appcast.markdown_inline_to_html("[x](https://example.com/a&b)")
        self.assertEqual(html, '<a href="https://example.com/a&amp;b">x</a>')

    def test_bullets_to_html_list(self):
        html = appcast.bullets_to_html_list(["one", "two **bold**"])
        self.assertEqual(html, "<ul><li>one</li><li>two <strong>bold</strong></li></ul>")

    def test_empty_bullets_still_valid_list(self):
        self.assertEqual(appcast.bullets_to_html_list([]), "<ul></ul>")


class MinSystemVersionTests(unittest.TestCase):
    def test_reads_from_project_yml_shape(self):
        text = (
            "options:\n"
            "  bundleIdPrefix: com.okamiops\n"
            "  deploymentTarget:\n"
            '    macOS: "26.0"\n'
        )
        self.assertEqual(appcast.read_min_system_version(text), "26.0")

    def test_missing_returns_none(self):
        self.assertIsNone(appcast.read_min_system_version("options:\n  foo: bar\n"))

    def test_real_project_yml(self):
        path = os.path.join(REPO_ROOT, "project.yml")
        with open(path, "r", encoding="utf-8") as fh:
            content = fh.read()
        version = appcast.read_min_system_version(content)
        self.assertIsNotNone(version)
        self.assertRegex(version, r"^\d+(\.\d+)*$")


class BuildItemXmlTests(unittest.TestCase):
    def _item(self, **overrides):
        params = dict(
            version="0.5.5",
            build="10",
            url="https://github.com/OkamiOps/okamiuni/releases/download/v0.5.5/OkamiUNI-0.5.5.zip",
            length=12345,
            signature="ZmFrZS1zaWduYXR1cmU=",
            release_page_url="https://github.com/OkamiOps/okamiuni/releases/tag/v0.5.5",
            min_system_version="26.0",
            pub_date="Tue, 13 Oct 2026 00:00:00 GMT",
            bullets_en=["First **bold**."],
            bullets_pt=["Primeiro **negrito**."],
        )
        params.update(overrides)
        return appcast.build_item_xml(**params)

    def test_contains_sparkle_fields(self):
        item = self._item()
        self.assertIn("<sparkle:version>10</sparkle:version>", item)
        self.assertIn(
            "<sparkle:shortVersionString>0.5.5</sparkle:shortVersionString>", item
        )
        self.assertIn(
            "<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>", item
        )
        self.assertIn(
            "<sparkle:fullReleaseNotesLink>"
            "https://github.com/OkamiOps/okamiuni/releases/tag/v0.5.5"
            "</sparkle:fullReleaseNotesLink>",
            item,
        )

    def test_enclosure_has_url_length_type_and_signature(self):
        item = self._item()
        self.assertIn(
            'url="https://github.com/OkamiOps/okamiuni/releases/download/v0.5.5/OkamiUNI-0.5.5.zip"',
            item,
        )
        self.assertIn('length="12345"', item)
        self.assertIn('type="application/octet-stream"', item)
        self.assertIn('sparkle:edSignature="ZmFrZS1zaWduYXR1cmU="', item)

    def test_descriptions_are_cdata_with_both_languages(self):
        item = self._item()
        self.assertIn('<description xml:lang="pt-BR"><![CDATA[', item)
        self.assertIn('<description xml:lang="en"><![CDATA[', item)
        self.assertIn("<strong>negrito</strong>", item)
        self.assertIn("<strong>bold</strong>", item)

    def test_signature_with_xml_special_chars_is_escaped_in_attribute(self):
        item = self._item(signature='abc"<>&def')
        self.assertIn(
            'sparkle:edSignature="abc&quot;&lt;&gt;&amp;def"', item
        )

    def test_item_is_well_formed_once_wrapped_in_rss(self):
        item = self._item(signature='weird"value&here')
        full = appcast.build_appcast_xml(None, item, "0.5.5")
        root = ET.fromstring(full)  # raises if not well-formed
        self.assertEqual(root.tag, "rss")


class BuildAppcastXmlTests(unittest.TestCase):
    def _make_item(self, version, build="1", signature="sig"):
        return appcast.build_item_xml(
            version=version,
            build=build,
            url=f"https://example.com/{version}.zip",
            length=100,
            signature=signature,
            release_page_url=f"https://example.com/release/{version}",
            min_system_version="26.0",
            pub_date="Tue, 13 Oct 2026 00:00:00 GMT",
            bullets_en=[f"Notes for {version}"],
            bullets_pt=[f"Notas da {version}"],
        )

    def test_fresh_appcast_is_valid_xml_with_one_item(self):
        item = self._make_item("0.5.5")
        full = appcast.build_appcast_xml(None, item, "0.5.5")
        root = ET.fromstring(full)
        items = root.findall("./channel/item")
        self.assertEqual(len(items), 1)

    def test_channel_metadata(self):
        item = self._make_item("0.5.5")
        full = appcast.build_appcast_xml(None, item, "0.5.5")
        root = ET.fromstring(full)
        channel = root.find("./channel")
        self.assertEqual(channel.find("title").text, "OkamiUNI")
        self.assertEqual(channel.find("link").text, appcast.CHANNEL_LINK)

    def test_prepends_new_item_and_keeps_older_ones(self):
        old_item = self._make_item("0.5.4")
        existing_xml = appcast.build_appcast_xml(None, old_item, "0.5.4")

        new_item = self._make_item("0.5.5")
        full = appcast.build_appcast_xml(existing_xml, new_item, "0.5.5")

        root = ET.fromstring(full)
        versions = [
            el.text
            for el in root.findall(
                "./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString"
            )
        ]
        self.assertEqual(versions, ["0.5.5", "0.5.4"])

    def test_replaces_item_with_same_version_instead_of_duplicating(self):
        first = self._make_item("0.5.5", build="10", signature="old-sig")
        existing_xml = appcast.build_appcast_xml(None, first, "0.5.5")

        second = self._make_item("0.5.5", build="10", signature="new-sig")
        full = appcast.build_appcast_xml(existing_xml, second, "0.5.5")

        root = ET.fromstring(full)
        items = root.findall("./channel/item")
        self.assertEqual(len(items), 1)
        enclosure = items[0].find("enclosure")
        self.assertEqual(
            enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"),
            "new-sig",
        )

    def test_three_versions_prepend_order(self):
        xml_1 = appcast.build_appcast_xml(None, self._make_item("0.5.3"), "0.5.3")
        xml_2 = appcast.build_appcast_xml(xml_1, self._make_item("0.5.4"), "0.5.4")
        xml_3 = appcast.build_appcast_xml(xml_2, self._make_item("0.5.5"), "0.5.5")

        root = ET.fromstring(xml_3)
        versions = [
            el.text
            for el in root.findall(
                "./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString"
            )
        ]
        self.assertEqual(versions, ["0.5.5", "0.5.4", "0.5.3"])


class ExtractExistingItemsTests(unittest.TestCase):
    def test_none_input_returns_empty(self):
        self.assertEqual(appcast.extract_existing_items(None), [])

    def test_empty_string_returns_empty(self):
        self.assertEqual(appcast.extract_existing_items(""), [])

    def test_item_version_extracts_short_version_string(self):
        item = appcast.build_item_xml(
            version="1.2.3",
            build="7",
            url="https://example.com/x.zip",
            length=1,
            signature="s",
            release_page_url="https://example.com/r",
            min_system_version="26.0",
            pub_date="Tue, 13 Oct 2026 00:00:00 GMT",
            bullets_en=["x"],
            bullets_pt=["y"],
        )
        self.assertEqual(appcast.item_version(item), "1.2.3")


class CliEndToEndTests(unittest.TestCase):
    """Exercita main() via arquivos temporários, sem subprocess."""

    def setUp(self):
        import tempfile

        self.tmpdir = tempfile.mkdtemp(prefix="appcast-test-")
        self.changelog_en = os.path.join(self.tmpdir, "CHANGELOG.md")
        self.changelog_pt = os.path.join(self.tmpdir, "CHANGELOG.pt-BR.md")
        self.project_yml = os.path.join(self.tmpdir, "project.yml")
        self.zip_path = os.path.join(self.tmpdir, "OkamiUNI-0.5.5.zip")
        self.appcast_path = os.path.join(self.tmpdir, "appcast.xml")

        with open(self.changelog_en, "w", encoding="utf-8") as fh:
            fh.write(CHANGELOG_EN_FIXTURE)
        with open(self.changelog_pt, "w", encoding="utf-8") as fh:
            fh.write(CHANGELOG_PT_FIXTURE)
        with open(self.project_yml, "w", encoding="utf-8") as fh:
            fh.write('options:\n  deploymentTarget:\n    macOS: "26.0"\n')
        with open(self.zip_path, "wb") as fh:
            fh.write(b"x" * 4321)

    def tearDown(self):
        import shutil

        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_main_writes_valid_appcast(self):
        rc = appcast.main(
            [
                "--version", "0.5.5",
                "--build", "10",
                "--zip", self.zip_path,
                "--signature", "abc123==",
                "--appcast", self.appcast_path,
                "--changelog", self.changelog_en,
                "--changelog-pt-br", self.changelog_pt,
                "--project-yml", self.project_yml,
            ]
        )
        self.assertEqual(rc, 0)
        with open(self.appcast_path, "r", encoding="utf-8") as fh:
            xml_text = fh.read()
        root = ET.fromstring(xml_text)
        enclosure = root.find("./channel/item/enclosure")
        self.assertEqual(enclosure.get("length"), "4321")
        self.assertEqual(
            enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"),
            "abc123==",
        )

    def test_main_errors_without_length_or_zip(self):
        rc = appcast.main(
            [
                "--version", "0.5.5",
                "--build", "10",
                "--signature", "abc123==",
                "--appcast", self.appcast_path,
                "--changelog", self.changelog_en,
                "--changelog-pt-br", self.changelog_pt,
                "--project-yml", self.project_yml,
            ]
        )
        self.assertNotEqual(rc, 0)

    def test_main_errors_on_missing_changelog_section(self):
        rc = appcast.main(
            [
                "--version", "9.9.9",
                "--build", "1",
                "--zip", self.zip_path,
                "--signature", "abc123==",
                "--appcast", self.appcast_path,
                "--changelog", self.changelog_en,
                "--changelog-pt-br", self.changelog_pt,
                "--project-yml", self.project_yml,
            ]
        )
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
