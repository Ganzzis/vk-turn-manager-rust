#!/usr/bin/env python3
import datetime
import runpy
import unittest
from pathlib import Path

signing = runpy.run_path(Path(__file__).with_name("check-signing.py"))


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.bundle = "test.example.vpn"
        self.team = "TEAM123456"
        self.udid = "synthetic-udid"
        self.group = "group.test.example.vpn"
        self.certificate = b"synthetic certificate"
        self.info = {"CFBundleIdentifier": self.bundle, "VKKeychainGroup": f"PREFIX1234.{self.bundle}.shared"}
        self.network = signing["NETWORK"]
        self.groups = signing["GROUPS"]
        self.keychain = signing["KEYCHAIN"]
        self.signed = {
            self.network: ["packet-tunnel-provider"],
            self.groups: [self.group],
            self.keychain: [self.info["VKKeychainGroup"]],
            signing["TEAM"]: self.team,
            signing["APPLICATION"]: f"PREFIX1234.{self.bundle}",
        }
        self.profile = {
            "TeamIdentifier": [self.team],
            "ApplicationIdentifierPrefix": ["PREFIX1234"],
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
            "ProvisionedDevices": [self.udid.upper()],
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {**self.signed, self.keychain: ["PREFIX1234.*"]},
        }

    def check(self, groups):
        return signing["check_target"](self.info, self.signed, self.profile, self.certificate,
                                       self.bundle, self.team, self.udid, groups)

    def test_app_group_optional(self):
        self.assertEqual(self.check({self.group}), self.info["VKKeychainGroup"])
        del self.signed[self.groups]
        del self.profile["Entitlements"][self.groups]
        self.assertEqual(self.check(set()), self.info["VKKeychainGroup"])

    def test_reject_missing_packet_tunnel_in_profile(self):
        self.profile["Entitlements"][self.network] = []
        with self.assertRaisesRegex(ValueError, "packet-tunnel-provider"):
            self.check({self.group})

    def test_reject_unapproved_app_group(self):
        self.profile["Entitlements"][self.groups] = []
        with self.assertRaisesRegex(ValueError, "App Groups"):
            self.check({self.group})

    def test_reject_wrong_keychain_prefix(self):
        self.profile["Entitlements"][self.keychain] = ["OTHERPREFIX.*"]
        with self.assertRaisesRegex(ValueError, "VKKeychainGroup"):
            self.check({self.group})

    def test_reject_unregistered_device(self):
        self.profile["ProvisionedDevices"] = []
        with self.assertRaisesRegex(ValueError, "iPhone"):
            self.check({self.group})

    def test_reject_expired_profile(self):
        self.profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.check({self.group})

    def test_reject_unapproved_certificate(self):
        self.profile["DeveloperCertificates"] = [b"other certificate"]
        with self.assertRaisesRegex(ValueError, "certificate"):
            self.check({self.group})


if __name__ == "__main__":
    unittest.main()
