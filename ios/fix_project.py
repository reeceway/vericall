#!/usr/bin/env python3
import re

with open('VeriCall.xcodeproj/project.pbxproj', 'r') as f:
    content = f.read()

if 'SelfVoiceEnrollmentView.swift' in content:
    print("Already added")
    exit(0)

sev_build = 'AA000041'
sev_ref = 'AA000142'
notif_build = 'AA000042'  
notif_ref = 'AA000143'
settings_ref = 'AA000141'
settings_group_id = 'AA000311'

content = content.replace(
    'AA000040 /* SettingsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000141 /* SettingsView.swift */; };',
    f'AA000040 /* SettingsView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = AA000141 /* SettingsView.swift */; }};\n\t\t{sev_build} /* SelfVoiceEnrollmentView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {sev_ref} /* SelfVoiceEnrollmentView.swift */; }};\n\t\t{notif_build} /* NotificationService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {notif_ref} /* NotificationService.swift */; }};'
)
print("Added build file entries")

content = content.replace(
    '/* End PBXFileReference section */',
    f'\t\t{settings_ref} /* SettingsView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsView.swift; sourceTree = "<group>"; }};\n\t\t{sev_ref} /* SelfVoiceEnrollmentView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SelfVoiceEnrollmentView.swift; sourceTree = "<group>"; }};\n\t\t{notif_ref} /* NotificationService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationService.swift; sourceTree = "<group>"; }};\n/* End PBXFileReference section */'
)
print("Added file references")

content = content.replace(
    'AA000118 /* VoiceEnrollmentView.swift */,',
    f'AA000118 /* VoiceEnrollmentView.swift */,\n\t\t\t\t\t\t{sev_ref} /* SelfVoiceEnrollmentView.swift */,'
)
print("Added to Onboarding group")

content = content.replace(
    'AA000130 /* VoiceVerificationService.swift */,',
    f'AA000130 /* VoiceVerificationService.swift */,\n\t\t\t\t\t\t{notif_ref} /* NotificationService.swift */,'
)
print("Added to Services group")

content = content.replace(
    'AA000029 /* VoiceVerificationService.swift in Sources */,',
    f'AA000029 /* VoiceVerificationService.swift in Sources */,\n\t\t\t\t\t\t{sev_build} /* SelfVoiceEnrollmentView.swift in Sources */,\n\t\t\t\t\t\t{notif_build} /* NotificationService.swift in Sources */,'
)
print("Added to Sources build phase")

content = content.replace(
    '/* End PBXGroup section */',
    f'\t\t{settings_group_id} /* Settings */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{settings_ref} /* SettingsView.swift */,\n\t\t\t);\n\t\t\tpath = Settings;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n/* End PBXGroup section */'
)

content = content.replace(
    'AA000209 /* Components */,',
    f'AA000209 /* Components */,\n\t\t\t\t\t\t{settings_group_id} /* Settings */,'
)
print("Added Settings group")

with open('VeriCall.xcodeproj/project.pbxproj', 'w') as f:
    f.write(content)
print("Done!")
