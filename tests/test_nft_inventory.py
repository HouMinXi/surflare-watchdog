#!/usr/bin/env python3
"""Check real shell call inventory against deliberately hostile source shapes."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
GATE = importlib.util.spec_from_file_location(
    'nft_gate', ROOT / 'scripts' / 'check_nft_locked_writes.py')
gate = importlib.util.module_from_spec(GATE)
GATE.loader.exec_module(gate)
CHECKER = ROOT / 'scripts/check_nft_locked_writes.py'
SPEC = importlib.util.spec_from_file_location('nft_inventory', CHECKER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InventoryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'candidate.sh'
        self.manifest = self.root / 'manifest.json'
        self.source.write_text('f() { nft -f one; }\n')
        records = MODULE.inventory(self.source)
        for record in records:
            record['reason'] = 'fixture baseline'
        self.manifest.write_text(json.dumps(records))

    def run_gate(self, text):
        self.source.write_text(text)
        return subprocess.run(
            [sys.executable, str(CHECKER), str(self.source), '--manifest',
             str(self.manifest)], capture_output=True, text=True, timeout=35, check=False,
        )

    def test_original_and_comments(self):
        for text in ('f() { nft -f one; }\n',
                     '# a comment\nf() { nft -f one; }\n'):
            result = self.run_gate(text)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_log_suffix_new_site(self):
        result = self.run_gate('f() { nft -f one; nft flush table inet a || log bad; }')
        self.assertEqual(result.returncode, 1)
        self.assertIn('new site', result.stdout)

    def test_heredoc_braces_are_not_function_ends(self):
        text = 'f() { cat <<EOF\n}\nEOF\nnft -f two; }\n'
        self.source.write_text(text)
        sites = MODULE.inventory(self.source)
        self.assertEqual([x['owner'] for x in sites], ['f'])
        self.assertEqual(self.run_gate(text).returncode, 1)

    def test_verbs_and_continuations(self):
        for call in ('nft delete chain inet a x', 'nft flush chain inet a x',
                     'nft destroy table inet a', 'nft \\\n-f one',
                     'nft -f one; nft -f one'):
            result = self.run_gate('f() { ' + call + '; }\n')
            if call == 'nft \\\n-f one':
                # A formatting-only continuation should not change argv.
                self.assertEqual(result.returncode, 0, result.stdout)
            else:
                self.assertEqual(result.returncode, 1, call)

    def test_literal_launchers_and_compound_writes(self):
        forms = (
            '/usr/sbin/nft destroy table inet a',
            'command nft delete chain inet a x',
            'exec nft flush table inet a',
            'timeout 1 nft flush table inet a',
            'env -i X=y nft flush table inet a',
            'env -u X nft flush table inet a',
            'env --unset X nft flush table inet a',
            'env --unset=X nft flush table inet a',
            'env --ignore-environment nft flush table inet a',
            'env -C / nft flush table inet a',
            'env --chdir=/ -- nft flush table inet a',
            'exec -a marker nft flush table inet a',
            'exec -amarker /usr/sbin/nft flush table inet a',
            'exec -c -l -a nft /usr/sbin/nft flush table inet a',
            'command -p -- env -u X timeout -k 1 2 nft flush table inet a',
            'nft list tables ";" flush table inet a',
            'nft --file=/no/file list tables',
            'nft -fone list tables',
        )
        for call in forms:
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)

    def test_unresolved_launchers_are_errors_not_empty_inventory(self):
        for call in (
            'env -S "nft flush table inet a"',
            'env --split-string="nft flush table inet a"',
            'exec --unknown nft flush table inet a',
            'env --unknown nft flush table inet a',
            'timeout --unknown 1 nft flush table inet a',
            'env -u',
        ):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 2, call + result.stdout)
            self.assertIn('nft write inventory unavailable', result.stderr)

    def test_escaped_spellings_of_the_same_words_are_writes(self):
        for call in (
            '\\nft destroy table inet a',
            'n\\ft destroy table inet a',
            '/usr/sbin/nf\\t destroy table inet a',
            'n"f"\'t\' destroy table inet a',
            'e\\nv -u X nft flush table inet a',
            'e\\nv -u X \\nft flush table inet a',
            'exe\\c -a marker nft flush table inet a',
            't\\imeout 1 nft flush table inet a',
        ):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)

    def test_escaped_read_only_is_still_read_only(self):
        # A read-only exemption must still be told apart from not being
        # recognised at all: the neighbouring write has to be reported.
        result = self.run_gate(
            'f() { nft -f one; \\nft list tables; nft flush table inet b; }')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('flush table inet b', result.stdout)
        self.assertNotIn('list tables', result.stdout)

    def test_ansi_c_quoting_is_the_same_command(self):
        for call in (
            "$'\\x6e\\x66\\x74' destroy table inet a",
            "$'\\156\\146\\164' destroy table inet a",
            "n$'\\x66't destroy table inet a",
            "/usr/sbin/$'nf\\x74' destroy table inet a",
            "$'e\\x6ev' -u X nft flush table inet a",
        ):
            result = self.run_gate("f() { nft -f one; " + call + "; }")
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)
            executed = result.stdout.split('(executes: ')[1]
            self.assertIn('nft ', executed)

    def test_ansi_c_read_only_stays_exempt(self):
        result = self.run_gate("f() { nft -f one; $'\\x6e\\x66\\x74' list tables; }")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_brace_expansion_is_refused_not_dropped(self):
        result = self.run_gate('f() { nft -f one; n{ft,ft} flush table inet a; }')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('brace expansion', result.stderr)

    def test_double_quoted_backslash_is_not_decoded(self):
        # Inside double quotes a backslash before an ordinary character stays
        # literal, so the shell runs the unknown command `n\ft`, not nft.
        result = self.run_gate('f() { nft -f one; "n\\ft" flush table inet a; }')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_ansi_c_nul_terminates_the_word(self):
        # The shell runs a word as a C string: an encoded NUL ends it, so all
        # of these execute nft. Verified with a marker executable in bash and
        # dash before writing the expectations.
        for call in (
            "$'\\x6e\\x66\\x74\\x00' destroy table inet a",
            "$'\\156\\146\\164\\000' destroy table inet a",
            "$'nf\\x00't destroy table inet a",
            "$'nft\\0' destroy table inet a",
        ):
            result = self.run_gate("f() { nft -f one; " + call + "; }")
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)

    def test_ansi_c_unicode_escapes_are_decoded(self):
        for call in ("$'\\u006e\\u0066\\u0074' destroy table inet a",
                     "$'\\U0000006e\\U00000066\\U00000074' destroy table inet a"):
            result = self.run_gate("f() { nft -f one; " + call + "; }")
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)

    def test_plain_single_quotes_keep_escapes_literal(self):
        # Only $'...' expands escapes; 'n\x66t' is the literal command name.
        result = self.run_gate("f() { nft -f one; 'n\\x66t' destroy table inet a; }")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_escape_table_entries_are_all_decoded(self):
        for text, expected in (
            ('\\n', '\n'), ('\\t', '\t'), ('\\r', '\r'), ('\\v', '\v'),
            ('\\f', '\f'), ('\\b', '\b'), ('\\a', '\a'), ('\\e', '\x1b'),
            ('\\\\', '\\'), ("\\'", "'"), ('\\"', '"'), ('\\?', '?'),
        ):
            self.assertEqual(gate.decode_ansi_c(text), expected, text)

    def test_braces_inside_quotes_are_not_treated_as_expansion(self):
        for call in ('"a{b,c}" flush table inet a', "'a{b,c}' flush table inet a"):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            # A clean run is required: another refusal reason would also pass a
            # "no brace message" check while rejecting legitimate source.
            self.assertEqual(result.returncode, 0,
                             call + result.stdout + result.stderr)
            self.assertNotIn('brace expansion', result.stderr, call)

    def test_launch_prefixes_do_not_hide_the_command(self):
        for call in (
            'nice -n 5 nft flush table inet a',
            'nice 5 nft flush table inet a',
            'nohup nft flush table inet a',
            'setsid nft flush table inet a',
            'ionice -c 3 nft flush table inet a',
            'stdbuf -oL nft flush table inet a',
            'nohup nice -n 5 ionice -c2 nft flush table inet a',
        ):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 1, call + result.stdout)

    def test_nice_adjustment_forms_are_parsed(self):
        for call in ('nice -5 nft flush table inet a',
                     'nice --adjustment 5 nft flush table inet a',
                     'nice --adjustment=5 nft flush table inet a'):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 1, call + result.stdout)
            self.assertIn('new site', result.stdout)
            self.assertIn('nft flush table inet a', result.stdout)

    def test_indirection_mentioning_nft_is_refused(self):
        for call in ("eval nft flush table inet a",
                     "sh -c 'nft flush table inet a'",
                     'sudo nft flush table inet a',
                     'busybox nft flush table inet a',
                     '$(command -v nft) flush table inet a'):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 2, call + result.stdout)
            self.assertIn('nft write inventory unavailable', result.stderr)

    def test_indirection_without_nft_is_not_a_write(self):
        for call in ('grep nft /tmp/list', 'sh -c true', 'sudo true'):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 0, call + result.stdout)

    def test_gate_covers_the_cli_as_well_as_the_daemon(self):
        # Two sources share the lock file; the wrapper invoices both.
        result = subprocess.run(
            [str(ROOT / 'scripts' / 'check-nft-locked-writes.sh')],
            cwd=ROOT, capture_output=True, text=True,
            env={'PATH': '/usr/local/bin:/usr/bin:/bin',
                 'SHFMT': os.environ.get('SHFMT', 'shfmt'),
                 'PYTHONDONTWRITEBYTECODE': '1'}, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('OK: 112 exact nft write sites', result.stdout)
        self.assertIn('OK: 22 exact nft write sites', result.stdout)

    def test_single_source_mode_selects_its_own_manifest(self):
        env = {'PATH': '/usr/local/bin:/usr/bin:/bin',
               'SHFMT': os.environ.get('SHFMT', 'shfmt'),
               'PYTHONDONTWRITEBYTECODE': '1'}
        script = str(ROOT / 'scripts' / 'check-nft-locked-writes.sh')
        daemon = subprocess.run([script, 'surflare_watchdog.sh'], cwd=ROOT,
                                capture_output=True, text=True, env=env,
                                check=False)
        self.assertEqual(daemon.returncode, 0, daemon.stdout + daemon.stderr)
        self.assertIn('OK: 112 exact', daemon.stdout)
        cli = subprocess.run([script, 'router/zoro-exit'], cwd=ROOT,
                             capture_output=True, text=True, env=env,
                             check=False)
        self.assertEqual(cli.returncode, 0, cli.stdout + cli.stderr)
        self.assertIn('OK: 22 exact', cli.stdout)
        stranger = subprocess.run([script, 'tests/test_nft_inventory.sh'],
                                  cwd=ROOT, capture_output=True, text=True,
                                  env=env, check=False)
        self.assertEqual(stranger.returncode, 2, stranger.stdout + stranger.stderr)
        self.assertIn('pass --manifest explicitly', stranger.stderr)
        # A path whose name merely contains "manifest" is not a --manifest flag.
        decoy = subprocess.run([script, 'tests/nft-manifest-probe.sh'],
                               cwd=ROOT, capture_output=True, text=True,
                               env=env, check=False)
        self.assertEqual(decoy.returncode, 2, decoy.stdout + decoy.stderr)
        self.assertIn('pass --manifest explicitly', decoy.stderr)
        # Other flags must reach the checker instead of being dropped.
        inventory = subprocess.run([script, 'surflare_watchdog.sh', '--inventory'],
                                   cwd=ROOT, capture_output=True, text=True,
                                   env=env, check=False)
        self.assertEqual(inventory.returncode, 0,
                         inventory.stdout + inventory.stderr)
        self.assertTrue(inventory.stdout.lstrip().startswith('['),
                        inventory.stdout[:200])

    def test_readme_lock_coverage_matches_the_manifest(self):
        """README quotes a split; recompute it so the prose cannot drift."""
        manifest = json.loads(
            (ROOT / 'scripts' / 'nft-write-sites.json').read_text())
        wrapped = [x for x in manifest if x['wrapped']]
        plain = [x for x in manifest if not x['wrapped']]
        self.assertEqual(len(manifest), 112)
        self.assertEqual(len(wrapped), 5)
        self.assertEqual(len(plain), 107)
        kinds = {'table/chain/set': 0, 'rule': 0, 'element': 0, 'other': 0}
        for site in plain:
            command = site['command']
            if re.search(r'\b(element)\b', command):
                kinds['element'] += 1
            elif re.search(r'\b(rule)\b', command):
                kinds['rule'] += 1
            elif re.search(r'\b(table|chain|set)\b', command):
                kinds['table/chain/set'] += 1
            else:
                kinds['other'] += 1
        self.assertEqual(kinds['table/chain/set'], 38)
        self.assertEqual(kinds['rule'], 31)
        self.assertEqual(kinds['element'], 17)
        self.assertEqual(kinds['other'], 21)
        batches = [x for x in plain if re.search(r'(^|\s)-f(\s|$)', ' ' + x['command'])]
        wrappers = [x for x in plain if x in plain and x['command'].startswith(('nft ${@}', 'timeout'))]
        self.assertEqual(len(batches), 18)
        self.assertEqual(len(wrappers), 3)
        readme = ' '.join((ROOT / 'README.md').read_text().replace('`', '').split())
        # Anchored, because a bare substring lets a leading digit rewrite a
        # pinned count ("138 table/chain/set writes" contains "38 ...").
        for phrase in ('38 table/chain/set writes', '31 rule writes',
                       '17 element updates', '18 nft -f batch loads',
                       '3 wrapper calls'):
            self.assertRegex(readme, r'(?<![0-9])' + re.escape(phrase))
        # The wrapped/plain half of the same sentence is pinned too.
        self.assertRegex(readme, r'(?<![0-9])112 enrolled sites')
        self.assertRegex(readme, r'(?<![0-9])five\s+are\s+wrapped')
        self.assertRegex(readme, r'(?<![0-9])107 break down')
        # Claims added for the defensive paths must be pinned too.
        self.assertIn('Five kinds of daemon write', readme)
        self.assertIn('_DNS_CLEANUP_MAX_DEFERRALS (default 3)', readme)
        self.assertIn('_DNS_CLEANUP_MIN_DEFER_SECS (default 60)', readme)
        self.assertIn('/run/surflare_dns_cleanup_defer', readme)
        self.assertIn('reason=service-stop-failed', readme)

    def test_unsupported_launch_prefix_option_is_refused(self):
        result = self.run_gate('f() { nft -f one; nice --unknown nft flush table inet a; }')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('nft write inventory unavailable', result.stderr)

    def test_quoted_spelling_keeps_enrollment_stable(self):
        # Escaping decides recognition; respelling an enrolled site is drift.
        # Both halves are required: the respelled site must be recognised
        # before it can be reported as drift against the original.
        result = self.run_gate('f() { n"f"\'t\' -f one; }')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('new site', result.stdout)
        self.assertIn('stale site', result.stdout)

    def test_escaped_split_string_launcher_is_refused(self):
        result = self.run_gate(
            'f() { nft -f one; e\\nv --split-string="nft flush table inet a"; }')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('nft write inventory unavailable', result.stderr)

    def test_discovery_and_direct_commands_do_not_add_sites(self):
        for call in ('command -v nft', 'command -V nft',
                     'env -u X true', 'exec -a marker true'):
            result = self.run_gate('f() { nft -f one; ' + call + '; }')
            self.assertEqual(result.returncode, 0, call + result.stdout)

    def test_read_word_in_write_is_not_exempt(self):
        result = self.run_gate('f() { nft add table inet list; }')
        self.assertEqual(result.returncode, 1)

    def test_stale_and_renamed_owner(self):
        for text in ('f() { nft list tables; nft -f two; }', 'g() { nft -f one; }'):
            result = self.run_gate(text)
            self.assertEqual(result.returncode, 1)
            self.assertIn('stale site', result.stdout)

    def test_heredoc_body_change(self):
        self.source.write_text('f() { nft -f - <<EOF\nflush table inet a\nEOF\n}\n')
        records = MODULE.inventory(self.source)
        for record in records:
            record['reason'] = 'fixture'
        self.manifest.write_text(json.dumps(records))
        result = self.run_gate('f() { nft -f - <<EOF\ndelete table inet a\nEOF\n}\n')
        self.assertEqual(result.returncode, 1)

    def test_missing_parser_and_invalid_shell_are_errors(self):
        result = self.run_gate('f() {')
        self.assertEqual(result.returncode, 2)
        env = dict(os.environ, SHFMT='/no/such/parser')
        result = subprocess.run(
            [sys.executable, str(CHECKER), str(self.source)], env=env,
            capture_output=True, text=True, timeout=35, check=False,
        )
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
