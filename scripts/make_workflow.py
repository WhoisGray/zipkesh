#!/usr/bin/env python3
"""Generate a real Automator Quick Action, using the installed launcher path."""
import argparse
from pathlib import Path
import plistlib
import shlex


def build_workflow(bundle: Path, launcher: Path) -> None:
    contents = bundle / "Contents"
    contents.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": "io.github.whoisgray.zipkesh.service",
        "CFBundleName": "Zipkesh — Encrypt Archive",
        "CFBundleShortVersionString": "1.0.0",
        "NSServices": [{
            "NSMenuItem": {"default": "Zipkesh — Encrypt Archive"},
            "NSMessage": "runWorkflowAsService",
            "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
            "NSSendFileTypes": ["public.item"],
        }],
    }
    shell_script = "exec " + shlex.quote(str(launcher)) + ' "$@"\n'
    document = {
        "AMApplicationBuild": "523",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [{
            "action": {
                "AMAccepts": {"Container": "List", "Optional": True, "Types": ["com.apple.cocoa.string"]},
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": {"COMMAND_STRING": {}, "CheckedForUserDefaultShell": {},
                                          "inputMethod": {}, "shell": {}, "source": {}},
                "AMProvides": {"Container": "List", "Types": ["com.apple.cocoa.string"]},
                "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                "ActionName": "Run Shell Script",
                "ActionParameters": {"COMMAND_STRING": shell_script, "CheckedForUserDefaultShell": True,
                                     "inputMethod": 1, "shell": "/bin/bash", "source": ""},
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "CanShowSelectedItemsWhenRun": False,
                "CanShowWhenRun": True,
                "Category": ["AMCategoryUtilities"],
                "Class Name": "RunShellScriptAction",
                "InputUUID": "1101CFA3-5D98-4BD6-B93F-B834B5A577AB",
                "OutputUUID": "61064C33-49BA-42D1-B4A2-0FCC11CD77AD",
                "UUID": "840060AE-9AF8-4F48-893D-4D065A10D50C",
                "isViewVisible": 1,
            },
            "isViewVisible": 1,
        }],
        "connectors": {},
        "workflowMetaData": {
            "applicationBundleID": "com.apple.finder",
            "applicationBundleIDsByPath": {"/System/Library/CoreServices/Finder.app": "com.apple.finder"},
            "applicationPath": "/System/Library/CoreServices/Finder.app",
            "applicationPaths": ["/System/Library/CoreServices/Finder.app"],
            "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
            "presentationMode": 11,
            "processesInput": 0,
            "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": 0,
            "systemImageName": "NSActionTemplate",
            "useAutomaticInputType": 0,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
        },
    }
    for filename, value in [("Info.plist", info), ("document.wflow", document)]:
        with (contents / filename).open("wb") as handle:
            plistlib.dump(value, handle)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("launcher", type=Path)
    arguments = parser.parse_args()
    build_workflow(arguments.bundle, arguments.launcher)
