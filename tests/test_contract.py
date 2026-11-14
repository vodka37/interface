import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "shake-goose.ps1").read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")


class ConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))

    def test_default_configuration_targets_androws(self) -> None:
        self.assertEqual(self.config["mode"], "auto")
        self.assertEqual(self.config["serial"], "127.0.0.1:5555")
        self.assertEqual(self.config["windowTitle"], "抓大鹅")

    def test_shake_timing_is_in_supported_range(self) -> None:
        self.assertIn(self.config["cycles"], range(1, 11))
        self.assertIn(self.config["intervalMs"], range(30, 1001))

    def test_all_configuration_keys_are_consumed(self) -> None:
        for key in self.config:
            self.assertRegex(SCRIPT, rf"\b{re.escape(key)}\b")


class DeliveryContractTests(unittest.TestCase):
    def test_powershell_sources_do_not_contain_smart_quotes(self) -> None:
        for path in ROOT.glob("*.ps1"):
            source = path.read_text(encoding="utf-8")
            for quote in "“”‘’":
                self.assertNotIn(
                    quote,
                    source,
                    f"{path.name} contains {quote!r}, which PowerShell treats as a quote delimiter",
                )

    def test_windows_powershell_51_loader_reads_localized_script_as_utf8(self) -> None:
        loader = (ROOT / "run-goose.ps1").read_text(encoding="ascii")
        self.assertIn("-Encoding UTF8", loader)
        self.assertIn('[ScriptBlock]::Create($source)', loader)
        self.assertIn("& $implementation @parameters", loader)

    def test_launcher_forwards_arguments_and_keeps_failures_visible(self) -> None:
        launcher = (ROOT / "一键颠锅.cmd").read_text(encoding="utf-8")
        self.assertIn('"%~dp0run-goose.ps1" %*', launcher)
        self.assertRegex(launcher, r"(?i)if errorlevel 1")
        self.assertRegex(launcher, r"(?i)\bpause\b")

    def test_auto_mode_has_adb_and_official_ui_paths(self) -> None:
        self.assertIn("Invoke-AdbShake", SCRIPT)
        self.assertIn('"emu", "sensor", "set", "acceleration"', SCRIPT)
        self.assertIn("Invoke-UiShake", SCRIPT)
        self.assertIn('@("摇一摇")', SCRIPT)
        self.assertLess(SCRIPT.index("Invoke-AdbShake"), SCRIPT.rindex("Invoke-UiShake"))

    def test_cycle_limit_is_hard_and_checked_before_actions(self) -> None:
        self.assertIn("$MaxCycles = 10", SCRIPT)
        validation = "if ($Cycles -lt 1 -or $Cycles -gt $MaxCycles)"
        self.assertIn(validation, SCRIPT)
        validation_position = SCRIPT.index(validation)
        self.assertLess(validation_position, SCRIPT.rindex("$adb = $null"))
        self.assertLess(validation_position, SCRIPT.rindex("Invoke-UiShake -Title"))
        self.assertIn("-Repeat $Cycles", SCRIPT)

    def test_runtime_is_bounded_and_all_explicit_loops_are_finite(self) -> None:
        self.assertIn("$MaxRuntimeSeconds = 30", SCRIPT)
        self.assertIn("$process.WaitForExit($timeoutMs)", SCRIPT)
        self.assertIn("$index -lt $Repeat", SCRIPT)
        self.assertNotRegex(SCRIPT, r"(?im)^\s*(while|do)\b")

    def test_ui_automation_does_not_inject_mouse_or_keyboard_input(self) -> None:
        powershell = "\n".join(
            path.read_text(encoding="utf-8") for path in ROOT.glob("*.ps1")
        )
        for forbidden_api in ("SetCursorPos", "mouse_event", "SendInput"):
            self.assertNotRegex(powershell, rf"(?i)\b{forbidden_api}\b")

    def test_tool_does_not_install_or_modify_android_packages(self) -> None:
        forbidden_adb_operations = ("install", "uninstall", "push", "pull", "root", "remount")
        adb_argument_lists = re.findall(
            r"Invoke-Adb\b.+?-Arguments\s+@\((.*?)\)",
            SCRIPT,
            flags=re.DOTALL,
        )
        flattened = "\n".join(adb_argument_lists).lower()
        for operation in forbidden_adb_operations:
            self.assertNotRegex(flattened, rf'["\']{operation}["\']')

    def test_readme_covers_setup_configuration_and_failures(self) -> None:
        for expected in (
            "连续点击“性能”7 次",
            "config.json",
            "常见问题",
            "https://sj.qq.com/faq/435",
            "https://sj.qq.com/faq/3878",
        ):
            self.assertIn(expected, README)


if __name__ == "__main__":
    unittest.main()
