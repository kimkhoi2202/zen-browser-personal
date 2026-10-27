"""Fail safely if the upstream add-ons layout or clean-base assumption changes."""
import unittest
from ui_patch import patch_addons_styles, ADDONS_CSS_MARKER


class AddonsStyles(unittest.TestCase):
    BASE = '#main { max-width: var(--page-main-content-width); }\n#main > addon-list > section,\nx { display: flex; }\n'

    def test_keeps_upstream_and_appends_overlay_once(self):
        result = patch_addons_styles(self.BASE, '.example { color: inherit; }\n')
        self.assertTrue(result.startswith(self.BASE.rstrip()))
        self.assertEqual(result.count(ADDONS_CSS_MARKER), 1)
        self.assertTrue(result.endswith('.example { color: inherit; }\n'))

    def test_rejects_already_patched_base(self):
        with self.assertRaisesRegex(RuntimeError, 'already patched'):
            patch_addons_styles(patch_addons_styles(self.BASE, ''), '')

    def test_rejects_changed_upstream_layout(self):
        for anchor in ['#main > addon-list > section,', 'max-width: var(--page-main-content-width);']:
            with self.subTest(anchor=anchor), self.assertRaisesRegex(RuntimeError, 'layout changed'):
                patch_addons_styles(self.BASE.replace(anchor, ''), '')
