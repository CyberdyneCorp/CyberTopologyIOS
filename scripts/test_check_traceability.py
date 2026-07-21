"""Unit tests for check_traceability.py (run: python3 -m unittest discover -s scripts)."""
import tempfile
import textwrap
import unittest
from pathlib import Path

import check_traceability as ct


class ParseSpecScenariosTests(unittest.TestCase):
    def test_parses_scenarios_per_capability(self):
        with tempfile.TemporaryDirectory() as tmp:
            specs = Path(tmp)
            (specs / "cap-a").mkdir()
            (specs / "cap-a" / "spec.md").write_text(
                textwrap.dedent(
                    """\
                    ### Requirement: Something
                    #### Scenario: First thing
                    - **WHEN** x
                    #### Scenario:   Padded name
                    body '#### Scenario: Not a heading' inside a line
                    """
                )
            )
            (specs / "cap-b").mkdir()
            (specs / "cap-b" / "spec.md").write_text("#### Scenario: Other\n")

            result = ct.parse_spec_scenarios(specs)

        self.assertEqual(
            result,
            {"cap-a": {"First thing", "Padded name"}, "cap-b": {"Other"}},
        )

    def test_empty_dir_yields_no_scenarios(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ct.parse_spec_scenarios(Path(tmp)), {})


class CheckTests(unittest.TestCase):
    SPECS = {"qa": {"Gate", "Run"}, "uv": {"Pack"}}

    def test_clean_map_has_no_problems(self):
        problems = ct.check(
            self.SPECS,
            mapped={"qa": {"Run": ["Suite/testRun"]}},
            pending={"qa": {"Gate"}, "uv": {"Pack"}},
        )
        self.assertEqual(problems, [])

    def test_unmapped_scenario_is_reported(self):
        problems = ct.check(self.SPECS, mapped={}, pending={"qa": {"Gate", "Run"}})
        self.assertEqual(len(problems), 1)
        self.assertIn("uv / Pack", problems[0])
        self.assertIn("UNMAPPED", problems[0])

    def test_empty_test_list_is_reported(self):
        problems = ct.check(
            self.SPECS,
            mapped={"qa": {"Run": []}},
            pending={"qa": {"Gate"}, "uv": {"Pack"}},
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("empty test list", problems[0])

    def test_mapped_and_pending_conflict_is_reported(self):
        problems = ct.check(
            self.SPECS,
            mapped={"qa": {"Run": ["Suite/testRun"]}},
            pending={"qa": {"Gate", "Run"}, "uv": {"Pack"}},
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("both mapped and pending", problems[0])

    def test_stale_yaml_entries_are_reported(self):
        problems = ct.check(
            self.SPECS,
            mapped={"qa": {"Removed scenario": ["Suite/testGone"]}},
            pending={"qa": {"Gate", "Run"}, "uv": {"Pack", "Ghost"}},
        )
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("qa / Removed scenario" in p and "stale" in p for p in problems))
        self.assertTrue(any("uv / Ghost" in p and "stale" in p for p in problems))

    def test_pending_capability_missing_from_specs_is_stale(self):
        problems = ct.check(
            self.SPECS,
            mapped={"qa": {"Run": ["Suite/testRun"], "Gate": ["Suite/testGate"]}},
            pending={"nonexistent-cap": {"Anything"}, "uv": {"Pack"}},
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("nonexistent-cap / Anything", problems[0])


class EndToEndTests(unittest.TestCase):
    def _write_repo(self, tmp: Path, yaml_text: str) -> tuple[Path, Path]:
        specs = tmp / "specs"
        (specs / "qa").mkdir(parents=True)
        (specs / "qa" / "spec.md").write_text(
            "#### Scenario: Gate\n#### Scenario: Run\n"
        )
        map_path = tmp / "traceability.yaml"
        map_path.write_text(yaml_text)
        return specs, map_path

    def test_main_passes_on_clean_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            specs, map_path = self._write_repo(
                Path(tmp),
                textwrap.dedent(
                    """\
                    scenarios:
                      qa:
                        Run:
                          - Suite/testRun
                    pending:
                      qa:
                        - Gate
                    """
                ),
            )
            rc = ct.main(["--specs-dir", str(specs), "--map", str(map_path)])
        self.assertEqual(rc, 0)

    def test_main_fails_on_unmapped(self):
        with tempfile.TemporaryDirectory() as tmp:
            specs, map_path = self._write_repo(
                Path(tmp), "scenarios:\npending:\n"
            )
            rc = ct.main(["--specs-dir", str(specs), "--map", str(map_path)])
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
