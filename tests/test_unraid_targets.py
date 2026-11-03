from contextlib import redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('targets', ROOT/'scripts/resolve-unraid.py')
targets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(targets)


def release(version, status='supported', public=True):
    return {'version': version, 'supportStatus': status, 'public': public,
            'changelog_pretty': f'https://docs.unraid.net/unraid-os/release-notes/{version}/'}


def notes(version, kernel):
    return f'<main><article><h1>Version {version} 2026-10-22</h1><h3>Linux kernel</h3><ul><li>Linux kernel: update to <code>{kernel}</code>.</li></ul></article></main>'


def archive(kernel='6.18.60-Unraid'):
    return {'tag_name': kernel, 'draft': False,
            'assets': [{'name': f'linux-{kernel}.tar.xz', 'state': 'uploaded', 'size': 100}]}


class UnraidTargetsTests(unittest.TestCase):
    def setUp(self):
        self.stable = release('7.3.4', 'security-updates')
        self.next = release('7.4.0-rc.2')
        self.catalog = [release('7.2.9', 'eol'), self.stable,
                        release('7.3.3', 'superseded'), self.next]
        self.pages = {entry['changelog_pretty']: notes(entry['version'], '6.18.58-Unraid') for entry in self.catalog}
        self.latest = archive()
        self.requests = []

    def fetch(self, url):
        self.requests.append(url)
        if url == targets.CATALOG_URL: return json.dumps(self.catalog)
        if url == targets.ICH777_URL: return json.dumps(self.latest)
        return self.pages[url]

    def test_current_stable_and_rc_share_kernel_and_ich_latest_is_added(self):
        result = targets.resolve(self.fetch)
        self.assertEqual(result['kernel_releases'], ['6.18.58-Unraid','6.18.60-Unraid'])
        self.assertEqual(result['stable']['version'], '7.3.4')
        self.assertEqual(result['next']['version'], '7.4.0-rc.2')
        self.assertEqual(len(self.requests), 4)

    def test_three_different_kernels_are_built_once_each(self):
        self.pages[self.next['changelog_pretty']] = notes('7.4.0-rc.2','6.18.59-Unraid')
        result = targets.resolve(self.fetch)
        self.assertEqual(result['kernel_releases'], ['6.18.58-Unraid','6.18.59-Unraid','6.18.60-Unraid'])

    def test_ich_latest_duplicate_is_not_rebuilt(self):
        self.latest = archive('6.18.58-Unraid')
        self.assertEqual(targets.resolve(self.fetch)['kernel_releases'], ['6.18.58-Unraid'])

    def test_no_prerelease_does_not_keep_old_rc_kernel(self):
        self.next['supportStatus'] = 'superseded'
        self.pages[self.next['changelog_pretty']] = notes('7.4.0-rc.2','6.18.59-Unraid')
        result = targets.resolve(self.fetch)
        self.assertIsNone(result['next'])
        self.assertEqual(result['kernel_releases'], ['6.18.58-Unraid','6.18.60-Unraid'])

    def test_new_current_releases_remove_old_fixed_kernel(self):
        self.stable.update(release('7.4.0'))
        self.next.update(release('7.5.0-beta.1'))
        self.pages[self.stable['changelog_pretty']] = notes('7.4.0','6.18.61-Unraid')
        self.pages[self.next['changelog_pretty']] = notes('7.5.0-beta.1','6.19.2-Unraid')
        self.latest = archive('6.19.3-Unraid')
        self.assertEqual(targets.resolve(self.fetch)['kernel_releases'], ['6.18.61-Unraid','6.19.2-Unraid','6.19.3-Unraid'])

    def test_catalog_version_sort_not_publish_date_or_catalog_order(self):
        self.catalog.append(release('7.3.10','security-updates'))
        self.pages[self.catalog[-1]['changelog_pretty']] = notes('7.3.10','6.18.61-Unraid')
        self.catalog.reverse()
        self.assertEqual(targets.resolve(self.fetch)['stable']['version'], '7.3.10')

    def test_rc_numeric_order_and_both_numbering_styles(self):
        for version in ('7.4.0-rc.10','7.4.0-rc10'):
            with self.subTest(version=version):
                entries = [self.stable,self.next,release(version),release('7.4.0-beta99')]
                self.assertEqual(targets.current_releases(entries)['next']['version'],version)

    def test_private_and_eol_release_are_never_build_targets(self):
        self.catalog += [release('9.0.0',public=False),release('8.0.0','eol')]
        self.assertEqual(targets.resolve(self.fetch)['stable']['version'], '7.3.4')

    def test_promoted_release_drops_its_older_rc(self):
        entries = [release('7.4.0'),self.next]
        self.assertIsNone(targets.current_releases(entries)['next'])

    def test_missing_or_unknown_catalog_information_fails_closed(self):
        bad = [[], {}, [self.next], [{'version':'7.4.0','public':True}],
               [release('7.4.0','unknown')], [release('future')],
               [self.stable,deepcopy(self.stable)], [{'version':'7.4.0','public':'true'}]]
        for catalog in bad:
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                targets.current_releases(catalog)

    def test_notes_version_must_match_catalog_not_just_versionless_rc_url(self):
        self.pages[self.next['changelog_pretty']] = notes('7.4.0-rc.3','6.18.59-Unraid')
        with self.assertRaisesRegex(ValueError,'catalog version'):
            targets.resolve(self.fetch)

    def test_notes_kernel_must_be_present_unique_and_from_main_content(self):
        for body in (
            '<main><h1>Version 7.3.4</h1><p>No kernel listed</p></main>',
            notes('7.3.4','6.18.58-Unraid').replace('</main>','Linux kernel: 6.18.59-Unraid</main>'),
            '<nav>Linux kernel: 6.18.58-Unraid</nav><main><h1>Version 7.3.4</h1></main>',
            notes('7.3.4','null'),
        ):
            with self.subTest(body=body), self.assertRaises(ValueError):
                targets.kernel_from_notes(body,'7.3.4')

    def test_kernel_label_accepts_version_format_and_normalizes_suffix(self):
        html = '<main><h1>Version 7.3.4</h1><p>Linux kernel: version: 6.18.58</p></main>'
        self.assertEqual(targets.kernel_from_notes(html,'7.3.4'),'6.18.58-Unraid')

    def test_catalog_cannot_direct_fetch_to_an_untrusted_notes_host(self):
        for url in ('http://docs.unraid.net/unraid-os/release-notes/7.3.4/',
                    'https://example.org/notes/', 'file:///etc/passwd'):
            self.stable['changelog_pretty'] = url
            with self.assertRaises(ValueError): targets.resolve(self.fetch)

    def test_bad_or_unfinished_ich_release_never_falls_back_to_a_previous_kernel(self):
        for latest in ({}, archive('../6.18.60-Unraid'), {**archive(),'draft':True},
                       {**archive(),'assets':[]}, {**archive(),'assets':[{'name':'linux-6.18.60-Unraid.tar.xz','state':'new','size':0}]}):
            self.latest = latest
            with self.subTest(latest=latest), self.assertRaises(ValueError): targets.resolve(self.fetch)

    def test_network_error_is_not_treated_as_no_test_release(self):
        def fetch(url):
            if url == self.next['changelog_pretty']: raise OSError('network failure')
            return self.fetch(url)
        with self.assertRaises(OSError): targets.resolve(fetch)

    def test_failure_emits_no_github_matrix_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'output'
            with patch.dict(os.environ,{'GITHUB_OUTPUT':str(output)}), patch.object(targets,'resolve',side_effect=ValueError('bad notes')):
                with self.assertRaises(ValueError): targets.main()
            self.assertFalse(output.exists())

    def test_success_records_channel_evidence_and_unique_matrix(self):
        result = targets.resolve(self.fetch)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'output'; summary = Path(directory)/'summary'
            with patch.dict(os.environ,{'GITHUB_OUTPUT':str(output),'GITHUB_STEP_SUMMARY':str(summary)}), patch.object(targets,'resolve',return_value=result), redirect_stdout(io.StringIO()):
                targets.main()
            self.assertEqual(json.loads(output.read_text().split('=',1)[1]),result['kernel_releases'])
            self.assertIn('7.3.4',summary.read_text())
            self.assertIn('7.4.0-rc.2',summary.read_text())
            self.assertIn('6.18.60-Unraid',summary.read_text())


if __name__ == '__main__':
    unittest.main()
