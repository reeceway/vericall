#!/usr/bin/env python3
"""
Fix the Xcode project to add Settings group and SettingsView.swift file reference
"""

PROJECT_FILE = "VeriCall.xcodeproj/project.pbxproj"

def main():
    with open(PROJECT_FILE, 'r') as f:
        content = f.read()
    
    # 1. Add the missing PBXFileReference for AA000141 (SettingsView.swift)
    # Find end of PBXFileReference section and add before it
    file_ref_entry = '\t\tAA000141 /* SettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsView.swift; sourceTree = "<group>"; };'
    
    # Find a good insertion point - after AA000140
    marker = 'AA000140 /* VoiceEnrollmentCompleteView.swift */ = {isa = PBXFileReference;'
    idx = content.find(marker)
    if idx != -1:
        # Find end of this line
        end_idx = content.find('};', idx) + 2
        content = content[:end_idx] + '\n' + file_ref_entry + content[end_idx:]
        print("Added SettingsView.swift PBXFileReference")
    
    # 2. Add Settings group (AA000311)
    settings_group = '''		AA000311 /* Settings */ = {
			isa = PBXGroup;
			children = (
				AA000141 /* SettingsView.swift */,
			);
			path = Settings;
			sourceTree = "<group>";
		};'''
    
    # Find Views group and add Settings after Components
    views_children_marker = 'AA000310 /* Components */,'
    idx = content.find(views_children_marker)
    if idx != -1:
        end_idx = idx + len(views_children_marker)
        content = content[:end_idx] + '\n\t\t\t\tAA000311 /* Settings */,' + content[end_idx:]
        print("Added Settings to Views children")
    
    # Add the Settings group definition - after Components group definition
    components_end_marker = '''		AA000310 /* Components */ = {
			isa = PBXGroup;
			children = (
				AA000136 /* AudioVisualizerView.swift */,
				AA000137 /* VoiceMatchIndicatorView.swift */,
			);
			path = Components;
			sourceTree = "<group>";
		};'''
    
    idx = content.find(components_end_marker)
    if idx != -1:
        end_idx = idx + len(components_end_marker)
        content = content[:end_idx] + '\n' + settings_group + content[end_idx:]
        print("Added Settings group definition")
    
    with open(PROJECT_FILE, 'w') as f:
        f.write(content)
    
    print(f"Fixed {PROJECT_FILE}")

if __name__ == "__main__":
    main()
