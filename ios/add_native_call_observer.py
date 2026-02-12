#!/usr/bin/env python3
"""
Script to add NativeCallObserver.swift to the VeriCall Xcode project
"""

filepath = "VeriCall.xcodeproj/project.pbxproj"

with open(filepath, 'r') as f:
    content = f.read()

# Check if already added
if 'NativeCallObserver.swift' in content:
    print("NativeCallObserver.swift already in project")
    exit(0)

# Generate unique IDs for the new file
FILE_REF_ID = "AA000144"  # PBXFileReference ID (next after AA000143)
BUILD_FILE_ID = "AA000043"  # PBXBuildFile ID (next after AA000042)

# 1. Add PBXBuildFile entry (after NotificationService build file)
notification_build = 'AA000042 /* NotificationService.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000143 /* NotificationService.swift */; };'
native_call_build = notification_build + '\n\t\t' + BUILD_FILE_ID + ' /* NativeCallObserver.swift in Sources */ = {isa = PBXBuildFile; fileRef = ' + FILE_REF_ID + ' /* NativeCallObserver.swift */; };'

if notification_build in content:
    content = content.replace(notification_build, native_call_build)
    print("Added PBXBuildFile entry")
else:
    print("WARNING: Could not find NotificationService build file entry")

# 2. Add PBXFileReference entry (after NotificationService file reference)
notification_ref = 'AA000143 /* NotificationService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationService.swift; sourceTree = "<group>"; };'
native_call_ref = notification_ref + '\n\t\t' + FILE_REF_ID + ' /* NativeCallObserver.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeCallObserver.swift; sourceTree = "<group>"; };'

if notification_ref in content:
    content = content.replace(notification_ref, native_call_ref)
    print("Added PBXFileReference entry")
else:
    print("WARNING: Could not find NotificationService file reference")

# 3. Add to Services group (find the Services children array)
services_notification = 'AA000143 /* NotificationService.swift */,'
services_with_native = services_notification + '\n\t\t\t\t\t\t' + FILE_REF_ID + ' /* NativeCallObserver.swift */,'

if services_notification in content:
    content = content.replace(services_notification, services_with_native)
    print("Added to Services group")
else:
    print("WARNING: Could not find NotificationService in Services group")

# 4. Add to Sources build phase
notification_sources = 'AA000042 /* NotificationService.swift in Sources */,'
sources_with_native = notification_sources + '\n\t\t\t\t' + BUILD_FILE_ID + ' /* NativeCallObserver.swift in Sources */,'

if notification_sources in content:
    content = content.replace(notification_sources, sources_with_native)
    print("Added to Sources build phase")
else:
    print("WARNING: Could not find NotificationService in Sources build phase")

# Write the file
with open(filepath, 'w') as f:
    f.write(content)

print("SUCCESS: NativeCallObserver.swift added to project")
