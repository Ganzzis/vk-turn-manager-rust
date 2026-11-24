#!/usr/bin/env python3
"""Check the signed device IPA and both embedded provisioning profiles."""

import argparse
import datetime
import plistlib
from pathlib import Path
import subprocess
import tempfile

NETWORK = "com.apple.developer.networking.networkextension"
GROUPS = "com.apple.security.application-groups"
KEYCHAIN = "keychain-access-groups"
TEAM = "com.apple.developer.team-identifier"
APPLICATION = "application-identifier"
PACKET_TUNNEL = "packet-tunnel-provider"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(program, *args):
    result = subprocess.run([program, *args], capture_output=True)
    require(result.returncode == 0, f"{Path(program).name} failed to {args[0]}")
    return result.stdout


def permitted(value, entries):
    return any(
        value == entry or (entry.endswith(".*") and value.startswith(entry[:-1]))
        for entry in entries
    )


def check_target(info, signed, profile, certificate, bundle_id, team, device, groups):
    require(info.get("CFBundleIdentifier") == bundle_id, "unexpected bundle identifier")
    require(signed.get(TEAM) == team and team in profile.get("TeamIdentifier", []),
            "unexpected signing team")
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, datetime.datetime) and
            expires.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
            "provisioning profile is expired or missing its expiration")
    devices = profile.get("ProvisionedDevices", [])
    require(device.lower() in [udid.lower() for udid in devices],
            "iPhone is not in the development or ad hoc provisioning profile")
    require(certificate in profile.get("DeveloperCertificates", []),
            "signing certificate is not in the profile")

    provisioned = profile["Entitlements"]
    require(provisioned.get(TEAM) == team, "provisioned team entitlement does not match")
    allowed_ids = [f"{prefix}.{bundle_id}" for prefix in profile.get("ApplicationIdentifierPrefix", [])]
    identifier = signed.get(APPLICATION)
    require(identifier in allowed_ids and identifier == provisioned.get(APPLICATION),
            "application identifier must match the explicit App ID in the profile")
    prefix = identifier.split(".", 1)[0]

    require(PACKET_TUNNEL in signed.get(NETWORK, []) and
            PACKET_TUNNEL in provisioned.get(NETWORK, []),
            "packet-tunnel-provider is required in the signature and profile")
    require(set(signed.get(GROUPS, [])) == groups and
            groups <= set(provisioned.get(GROUPS, [])),
            "signed or provisioned App Groups do not match the requested groups")

    keychain = info.get("VKKeychainGroup", "")
    require(keychain.startswith(f"{prefix}.") and "*" not in keychain and
            keychain in signed.get(KEYCHAIN, []) and
            permitted(keychain, provisioned.get(KEYCHAIN, [])),
            "VKKeychainGroup is not a concrete access group allowed by the signature and profile")
    return keychain


def inspect(bundle, certificate_prefix, *expected):
    run("/usr/bin/codesign", "--verify", "--strict", str(bundle))
    signed = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)))
    profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i",
                                 str(bundle / "embedded.mobileprovision")))
    run("/usr/bin/codesign", "-d", f"--extract-certificates={certificate_prefix}", str(bundle))
    certificate = Path(f"{certificate_prefix}0").read_bytes()
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    return info, check_target(info, signed, profile, certificate, *expected)


def check_ipa(args, scratch):
    run("/usr/bin/ditto", "-x", "-k", str(args.ipa), str(scratch))
    apps = list((scratch / "Payload").glob("*.app"))
    require(len(apps) == 1, "IPA must contain one application")
    app = apps[0]
    tunnel = app / "PlugIns" / "PacketTunnel.appex"
    require(tunnel.is_dir(), "embedded PacketTunnel.appex is missing")
    groups = set(args.app_group)
    _, app_keychain = inspect(app, scratch / "app-cert-", args.bundle_id, args.team_id,
                              args.device_udid, groups)
    info, tunnel_keychain = inspect(tunnel, scratch / "tunnel-cert-", args.bundle_id + ".packet-tunnel",
                                    args.team_id, args.device_udid, groups)
    extension = info.get("NSExtension", {})
    require(extension.get("NSExtensionPointIdentifier") == "com.apple.networkextension.packet-tunnel" and
            extension.get("NSExtensionPrincipalClass", "").endswith(".PacketTunnelProvider"),
            "PacketTunnel.appex declares the wrong extension point or provider class")
    require(app_keychain == tunnel_keychain, "application and extension use different Keychain groups")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, help="development or ad hoc IPA exported on macOS")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--device-udid", required=True)
    parser.add_argument("--app-group", action="append", default=[], help="expected group ID, repeatable")
    args = parser.parse_args()
    try:
        require(all(group.startswith("group.") and "*" not in group for group in args.app_group),
                "expected App Groups must be concrete group.* identifiers")
        with tempfile.TemporaryDirectory() as temporary:
            check_ipa(args, Path(temporary))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"IPA signing check failed: {error}\n")
    print("IPA signatures, provisioning profiles, and Packet Tunnel entitlements passed.")


if __name__ == "__main__":
    main()
