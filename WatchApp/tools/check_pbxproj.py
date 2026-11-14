#!/usr/bin/env python3
"""Checks the hand-written Xcode project for referential integrity, without Xcode.

    python3 WatchApp/tools/check_pbxproj.py [path/to/project.pbxproj]

The project file is an old-style property list; `plutil` converts it to JSON. Every check
that fails is printed, and the exit status is the number of failures (0 = all good).
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = os.path.join(HERE, "..", "Gauntlet.xcodeproj", "project.pbxproj")
ID = re.compile(r"^[0-9A-F]{24}$")

failures = []
passed = 0


def check(condition, message):
    global passed
    if condition:
        passed += 1
    else:
        failures.append(message)
    return condition


def walk(value):
    """Every string anywhere inside a plist value (dictionary keys included)."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from walk(item)


def main():
    path = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    project_dir = os.path.dirname(os.path.dirname(path))        # the folder holding the .xcodeproj

    lint = subprocess.run(["plutil", "-lint", path], capture_output=True, text=True)
    check(lint.returncode == 0, f"plutil -lint failed: {lint.stdout.strip()} {lint.stderr.strip()}")
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if not check(converted.returncode == 0, f"plutil could not convert the project: {converted.stderr.strip()}"):
        return report()
    plist = json.loads(converted.stdout)
    objects = plist.get("objects", {})

    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    check(text.startswith("// !$*UTF8*$!"), "missing the '// !$*UTF8*$!' header")
    check(str(plist.get("objectVersion")) == "77", f"objectVersion is {plist.get('objectVersion')}, expected 77")
    check(str(plist.get("archiveVersion")) == "1", "archiveVersion is not 1")

    # --- object IDs -------------------------------------------------------------------
    for key, obj in objects.items():
        check(bool(ID.match(key)), f"object ID {key!r} is not 24 upper-case hex digits")
        check(isinstance(obj, dict) and "isa" in obj, f"object {key} has no isa")
    declared = re.findall(r"^\t\t([0-9A-F]{24})(?: /\*.*?\*/)? = \{", text, flags=re.M)
    check(len(declared) == len(set(declared)), "an object ID is defined more than once")
    check(set(declared) == set(objects), "object IDs in the text and in the parsed plist differ")

    # Every 24-hex token anywhere (values, array items, dictionary keys) must be an object.
    referenced = {s for s in walk(plist) if ID.match(s)}
    for missing in sorted(referenced - set(objects)):
        check(False, f"dangling reference: {missing} is used but never defined")
    check(bool(referenced), "no object references found at all")
    # ... and the raw text agrees (catches IDs that only appear in malformed places).
    for token in sorted(set(re.findall(r"\b[0-9A-F]{24}\b", text)) - set(objects)):
        check(False, f"dangling reference in the text: {token}")

    def obj(ident, what, isa=None):
        found = objects.get(ident) if isinstance(ident, str) else None
        if not check(found is not None, f"{what}: {ident!r} does not resolve to an object"):
            return {}
        if isa is not None:
            allowed = isa if isinstance(isa, tuple) else (isa,)
            check(found.get("isa") in allowed, f"{what}: {ident} is a {found.get('isa')}, expected {' or '.join(allowed)}")
        return found

    def config_list(ident, what):
        configs = obj(ident, what, "XCConfigurationList")
        names = []
        for config_id in configs.get("buildConfigurations", []):
            config = obj(config_id, f"{what} configuration", "XCBuildConfiguration")
            names.append(config.get("name"))
            check(isinstance(config.get("buildSettings"), dict), f"{what}: configuration {config_id} has no buildSettings")
        check(sorted(str(n) for n in names if n) == ["Debug", "Release"], f"{what}: configurations are {names}, expected Debug and Release")
        check(configs.get("defaultConfigurationName") in names, f"{what}: defaultConfigurationName is not one of {names}")
        return [objects[c] for c in configs.get("buildConfigurations", []) if c in objects]

    # --- project ----------------------------------------------------------------------
    root_id = plist.get("rootObject")
    project = obj(root_id, "rootObject", "PBXProject")
    main_group = obj(project.get("mainGroup"), "project.mainGroup", "PBXGroup")
    obj(project.get("productRefGroup"), "project.productRefGroup", "PBXGroup")
    check(project.get("productRefGroup") in main_group.get("children", []), "the Products group is not inside the main group")
    project_configs = config_list(project.get("buildConfigurationList"), "project")
    for target_id in project.get("attributes", {}).get("TargetAttributes", {}):
        check(target_id in project.get("targets", []), f"TargetAttributes mentions {target_id}, which is not a target")

    # Groups: every child resolves, and nothing is in two groups.
    seen_children = {}
    for ident, group in objects.items():
        if group.get("isa") != "PBXGroup":
            continue
        for child in group.get("children", []):
            obj(child, f"group {ident} child",
                ("PBXGroup", "PBXFileReference", "PBXFileSystemSynchronizedRootGroup", "PBXVariantGroup"))
            check(child not in seen_children, f"{child} is a child of both {seen_children.get(child)} and {ident}")
            seen_children[child] = ident

    # --- local package ----------------------------------------------------------------
    packages = project.get("packageReferences", [])
    check(len(packages) == 1, f"expected one package reference, found {len(packages)}")
    package_products = set()
    for package_id in packages:
        package = obj(package_id, "project.packageReferences", "XCLocalSwiftPackageReference")
        relative = package.get("relativePath")
        check(relative == "..", f"local package relativePath is {relative!r}, expected '..'")
        package_dir = os.path.normpath(os.path.join(project_dir, relative or ""))
        manifest = os.path.join(package_dir, "Package.swift")
        if check(os.path.isfile(manifest), f"no Package.swift in {package_dir}"):
            with open(manifest, encoding="utf-8") as handle:
                package_products = set(re.findall(r'\.library\(\s*name:\s*"([^"]+)"', handle.read()))

    # --- targets ----------------------------------------------------------------------
    targets = project.get("targets", [])
    check(len(targets) == 1, f"expected one target, found {len(targets)}")
    wanted_products = {"GauntletProtocol", "GauntletLink", "GauntletWatchCore", "GauntletEngine"}
    for target_id in targets:
        target = obj(target_id, "project.targets", "PBXNativeTarget")
        name = target.get("name")
        check(name == "Gauntlet Watch App", f"target is named {name!r}")
        check(target.get("productType") == "com.apple.product-type.application", f"productType is {target.get('productType')!r}")

        product = obj(target.get("productReference"), "target.productReference", "PBXFileReference")
        check(product.get("sourceTree") == "BUILT_PRODUCTS_DIR", "the product is not in BUILT_PRODUCTS_DIR")
        check(product.get("explicitFileType") == "wrapper.application", "the product is not an application wrapper")
        check(target.get("productReference") in objects.get(project.get("productRefGroup"), {}).get("children", []),
              "the product is not listed in the Products group")

        phases = [obj(p, "target.buildPhases") for p in target.get("buildPhases", [])]
        kinds = [p.get("isa") for p in phases]
        for kind in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
            check(kinds.count(kind) == 1, f"expected exactly one {kind}, found {kinds.count(kind)}")
        linked = set()
        for phase in phases:
            for file_id in phase.get("files", []):
                build_file = obj(file_id, f"{phase.get('isa')} file", "PBXBuildFile")
                check(("productRef" in build_file) != ("fileRef" in build_file), f"build file {file_id} needs a productRef or a fileRef")
                if "productRef" in build_file:
                    dependency = obj(build_file["productRef"], f"build file {file_id} productRef", "XCSwiftPackageProductDependency")
                    check(phase.get("isa") == "PBXFrameworksBuildPhase", f"package product {file_id} is not in the Frameworks phase")
                    check(build_file["productRef"] in target.get("packageProductDependencies", []),
                          f"build file {file_id} links a product the target does not depend on")
                    linked.add(dependency.get("productName"))
                else:
                    obj(build_file["fileRef"], f"build file {file_id} fileRef")
        for ident, build_file in objects.items():
            if build_file.get("isa") == "PBXBuildFile":
                check(any(ident in p.get("files", []) for p in phases), f"build file {ident} is not in any build phase")

        depended = set()
        for dependency_id in target.get("packageProductDependencies", []):
            dependency = obj(dependency_id, "target.packageProductDependencies", "XCSwiftPackageProductDependency")
            depended.add(dependency.get("productName"))
            if "package" in dependency:
                obj(dependency["package"], f"dependency {dependency_id} package")
        check(depended == wanted_products, f"package product dependencies are {sorted(map(str, depended))}")
        check(linked == wanted_products, f"products linked in the Frameworks phase are {sorted(map(str, linked))}")
        check(wanted_products <= package_products, f"Package.swift does not export {sorted(wanted_products - package_products)}")

        synchronized = target.get("fileSystemSynchronizedGroups", [])
        check(len(synchronized) == 1, f"expected one synchronized group, found {len(synchronized)}")
        for group_id in synchronized:
            group = obj(group_id, "target.fileSystemSynchronizedGroups", "PBXFileSystemSynchronizedRootGroup")
            check(group_id in main_group.get("children", []), "the synchronized group is not in the main group")
            source_dir = os.path.join(project_dir, group.get("path", ""))
            if check(os.path.isdir(source_dir), f"synchronized folder {source_dir} does not exist"):
                swift, basenames, other = [], {}, []
                for folder, _, files in os.walk(source_dir):
                    for file in files:
                        full = os.path.join(folder, file)
                        if file.endswith(".swift"):
                            swift.append(full)
                            check(file not in basenames, f"two Swift files are both named {file} (not allowed in one module)")
                            basenames[file] = full
                        elif not file.startswith("."):
                            other.append(os.path.relpath(full, project_dir))
                check(len(swift) > 0, "the synchronized folder has no Swift sources")
                check(not other, f"non-source files in the synchronized folder would be bundled as resources: {other}")
                mains = [f for f in swift if re.search(r"^@main\b", open(f, encoding="utf-8").read(), flags=re.M)]
                check(len(mains) == 1, f"expected exactly one @main, found {len(mains)}")

        # Build settings.
        target_configs = config_list(target.get("buildConfigurationList"), "target")
        expected = {
            "SDKROOT": "watchos",
            "TARGETED_DEVICE_FAMILY": "4",
            "WATCHOS_DEPLOYMENT_TARGET": "11.0",
            "SWIFT_VERSION": "5.0",
            "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_FILE": "Config/Info.plist",
            "CODE_SIGN_ENTITLEMENTS": "Config/Gauntlet.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.sunhacks.gauntlet.watch",
            "ENABLE_PREVIEWS": "YES",
        }
        for config in target_configs:
            settings = config.get("buildSettings", {})
            label = f"target {config.get('name')}"
            for key, value in expected.items():
                check(str(settings.get(key)) == value, f"{label}: {key} is {settings.get(key)!r}, expected {value!r}")
            for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"):
                file_path = os.path.join(project_dir, str(settings.get(key, "")))
                if check(os.path.isfile(file_path), f"{label}: {key} points at {file_path}, which does not exist"):
                    ok = subprocess.run(["plutil", "-lint", file_path], capture_output=True, text=True)
                    check(ok.returncode == 0, f"{label}: {file_path} is not a valid property list")
                    inside = any(os.path.abspath(file_path).startswith(os.path.join(project_dir, objects[g].get("path", "")) + os.sep)
                                 for g in synchronized if g in objects)
                    check(not inside, f"{label}: {key} lives inside the synchronized folder and would be processed twice")
            product_name = str(settings.get("PRODUCT_NAME", "")).replace("$(TARGET_NAME)", name or "")
            check(product_name + ".app" == product.get("path"), f"{label}: product is {product_name}.app but the reference says {product.get('path')}")
        for config in project_configs:
            settings = config.get("buildSettings", {})
            check(settings.get("SDKROOT") == "watchos", f"project {config.get('name')}: SDKROOT is {settings.get('SDKROOT')!r}")
            check(str(settings.get("WATCHOS_DEPLOYMENT_TARGET")) == "11.0", f"project {config.get('name')}: deployment target")

        # Info.plist and entitlements content.
        info_path = os.path.join(project_dir, "Config", "Info.plist")
        if os.path.isfile(info_path):
            info = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", info_path],
                                             capture_output=True, text=True).stdout or "{}")
            check(info.get("WKApplication") is True, "Info.plist: WKApplication is not true")
            check(info.get("WKWatchOnly") is True, "Info.plist: WKWatchOnly is not true")
            for key in ("NSBluetoothAlwaysUsageDescription", "NSMotionUsageDescription",
                        "NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"):
                check(len(str(info.get(key, ""))) >= 40, f"Info.plist: {key} is missing or too vague")
            check("workout-processing" in info.get("WKBackgroundModes", []), "Info.plist: WKBackgroundModes lacks workout-processing")
            check(info.get("UIBackgroundModes") == ["bluetooth-central"], "Info.plist: UIBackgroundModes is not [bluetooth-central]")
        entitlements_path = os.path.join(project_dir, "Config", "Gauntlet.entitlements")
        if os.path.isfile(entitlements_path):
            entitlements = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", entitlements_path],
                                                     capture_output=True, text=True).stdout or "{}")
            check(entitlements.get("com.apple.developer.healthkit") is True, "entitlements: healthkit is not true")
            check(entitlements.get("com.apple.developer.healthkit.access") == [], "entitlements: healthkit.access is not an empty array")

    # File references inside ordinary groups must exist on disk.
    def group_path(ident):
        parent = seen_children.get(ident)
        base = group_path(parent) if parent else project_dir
        return os.path.join(base, objects[ident].get("path", "")) if objects[ident].get("path") else base

    for ident, ref in objects.items():
        if ref.get("isa") == "PBXFileReference" and ref.get("sourceTree") == "<group>":
            check(ident in seen_children, f"file reference {ident} is not in any group")
            check(os.path.exists(group_path(ident)), f"file reference {ident} points at {group_path(ident)}, which does not exist")

    # Every object is reachable from the root (nothing orphaned).
    reachable, stack = set(), [root_id]
    while stack:
        current = stack.pop()
        if current in reachable or current not in objects:
            continue
        reachable.add(current)
        stack.extend(s for s in walk(objects[current]) if ID.match(s))
    for orphan in sorted(set(objects) - reachable):
        check(False, f"object {orphan} ({objects[orphan].get('isa')}) is not reachable from the project")

    return report(len(objects))


def report(count=0):
    for failure in failures:
        print("FAIL " + failure)
    print(f"{count} objects, {passed} checks passed, {len(failures)} failed")
    return len(failures)


if __name__ == "__main__":
    sys.exit(min(main(), 255))
