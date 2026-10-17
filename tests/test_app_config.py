import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/generate_app_config.py"


class AppConfigTests(unittest.TestCase):
    def generate(self, content):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / ".env"
            destination = Path(directory) / "AppConfig.plist"
            source.write_text(content, encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), str(source), str(destination)],
                                    capture_output=True, text=True)
            values = plistlib.loads(destination.read_bytes()) if destination.exists() else None
            return result, values

    def test_only_public_configuration_is_bundled(self):
        result, values = self.generate(
            'APP_SERVER_URL=https://api.example.test\n'
            'APP_OPERATOR_NAME="IntoL 運営"\n'
            'APP_SUPPORT_EMAIL=help@example.test\n'
            'APP_PRIVACY_POLICY_URL=https://example.test/privacy\n'
            'DISCORD_FEEDBACK_WEBHOOK_URL=https://secret.example/webhook\n'
            'CHORUS_SYNC_TOKEN=server-only-secret\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["APP_OPERATOR_NAME"], "IntoL 運営")
        self.assertEqual(values["APP_MONETIZATION_ENABLED"], "false")
        self.assertNotIn("DISCORD_FEEDBACK_WEBHOOK_URL", values)
        self.assertNotIn("CHORUS_SYNC_TOKEN", values)

    def test_rejects_credentials_and_non_https_public_links(self):
        for key in ("APP_PRIVACY_POLICY_URL", "APP_SUPPORT_FORM_URL"):
            for value in ("http://example.test/privacy", "https://user:password@example.test/privacy",
                          "javascript:alert(1)", "https://example.test/form#fragment"):
                with self.subTest(key=key, value=value):
                    result, values = self.generate(f"{key}={value}\n")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIsNone(values)

    def test_monetization_requires_an_explicit_boolean_and_product(self):
        for content in ("APP_MONETIZATION_ENABLED=yes\n", "APP_MONETIZATION_ENABLED=true\n"):
            result, values = self.generate(content)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(values)
        result, values = self.generate("APP_MONETIZATION_ENABLED=true\nAPP_AD_REMOVAL_PRODUCT_ID=test.remove_ads\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["APP_AD_REMOVAL_PRODUCT_ID"], "test.remove_ads")

    def test_rejects_email_url_parameter_injection(self):
        result, values = self.generate("APP_SUPPORT_EMAIL=help@example.test?bcc=other@example.test\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(values)

    def test_google_sites_support_does_not_require_public_email(self):
        support_url = "https://sites.google.com/view/intol-example/support"
        privacy_url = "https://sites.google.com/view/intol-example/privacy"
        result, values = self.generate(
            f"APP_SUPPORT_URL={support_url}\n"
            f"APP_PRIVACY_POLICY_URL={privacy_url}\n"
            "APP_SUPPORT_EMAIL=\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["APP_SUPPORT_URL"], support_url)
        self.assertEqual(values["APP_PRIVACY_POLICY_URL"], privacy_url)
        self.assertEqual(values["APP_SUPPORT_EMAIL"], "")
        self.assertEqual(values["APP_MONETIZATION_ENABLED"], "false")

    def test_support_email_is_optional_when_omitted(self):
        result, values = self.generate("APP_SUPPORT_URL=https://sites.google.com/view/intol-example/support\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["APP_SUPPORT_EMAIL"], "")

    def test_direct_support_form_preserves_respondent_url(self):
        form_url = "https://docs.google.com/forms/d/e/example/viewform?usp=header"
        result, values = self.generate(f"APP_SUPPORT_FORM_URL={form_url}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["APP_SUPPORT_FORM_URL"], form_url)
        self.assertEqual(values["APP_SUPPORT_EMAIL"], "")


if __name__ == "__main__":
    unittest.main()
