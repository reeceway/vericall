#!/usr/bin/env python3
"""
Add missing Swift files to Xcode project.pbxproj
"""
import re
import uuid

PROJECT_FILE = "VeriCall.xcodeproj/project.pbxproj"

# Files to add with their group paths
NEW_FILES = [
    ("VeriCall/App/AppDelegate.swift", "App"),
    ("VeriCall/Services/NativeCallObserver.swift", "Services"),
    ("VeriCall/Services/NotificationService.swift", "Services"),
    ("VeriCall/Services/MoQTransportService.swift", "Services"),
    ("VeriCall/Views/Onboarding/SelfVoiceEnrollmentView.swift", "Views/Onboarding"),
]

def generate_uuid():
    """Generate a 24-char hex UUID for Xcode"""
    return uuid.uuid4().hex[:24].upper()

def main():
    with open(PROJECT_FILE, 'r') as f:
        content = f.read()
    
    # For each file, we need to add:
    # 1. PBXBuildFile entry (for Sources build phase)
    # 2. PBXFileReference entry (the actual file reference)
    # 3. Add to the appropriate group's children
    # 4. Add to PBXSourcesBuildPhase
    
    build_file_entries = []
    file_ref_entries = []
    sources_entries = []
    group_additions = {}
    
    for file_path, group in NEW_FILES:
        filename = file_path.split('/')[-1]
        
        # Check if already in project
        if filename in content:
            print(f"Skipping {filename} - already in project")
            continue
            
        file_ref_uuid = generate_uuid()
        build_file_uuid = generate_uuid()
        
        # PBXBuildFile entry
        build_file_entries.append(
            f"\t\t{build_file_uuid} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {filename} */; }};"
        )
        
        # PBXFileReference entry
        file_ref_entries.append(
            f"\t\t{file_ref_uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = \"<group>\"; }};"
        )
        
        # Track for group addition
        if group not in group_additions:
            group_additions[group] = []
        group_additions[group].append((file_ref_uuid, filename))
        
        # Track for sources build phase
        sources_entries.append(f"\t\t\t\t{build_file_uuid} /* {filename} in Sources */,")
        
        print(f"Adding {filename} to {group}")
    
    if not build_file_entries:
        print("No files to add")
        return
    
    # Insert PBXBuildFile entries after existing ones
    build_file_marker = "/* Begin PBXBuildFile section */"
    idx = content.find(build_file_marker)
    if idx != -1:
        insert_pos = content.find('\n', idx) + 1
        content = content[:insert_pos] + '\n'.join(build_file_entries) + '\n' + content[insert_pos:]
    
    # Insert PBXFileReference entries after existing ones
    file_ref_marker = "/* Begin PBXFileReference section */"
    idx = content.find(file_ref_marker)
    if idx != -1:
        insert_pos = content.find('\n', idx) + 1
        content = content[:insert_pos] + '\n'.join(file_ref_entries) + '\n' + content[insert_pos:]
    
    # Add files to their groups
    for group_name, files in group_additions.items():
        # Find the group - look for the pattern with the group name
        if group_name == "App":
            pattern = r'(children = \(\s*\n\s*[A-F0-9]+ /\* VeriCallApp\.swift \*/,)'
        elif group_name == "Services":
            pattern = r'(children = \(\s*\n\s*[A-F0-9]+ /\* APIService\.swift \*/,)'
        elif group_name == "Views/Onboarding":
            pattern = r'(children = \(\s*\n\s*[A-F0-9]+ /\* WelcomeView\.swift \*/,)'
        else:
            continue
            
        match = re.search(pattern, content)
        if match:
            additions = '\n'.join([f"\t\t\t\t{uuid} /* {name} */," for uuid, name in files])
            content = content[:match.end()] + '\n' + additions + content[match.end():]
    
    # Add to sources build phase
    sources_marker = "/* Begin PBXSourcesBuildPhase section */"
    files_marker = "files = ("
    idx = content.find(sources_marker)
    if idx != -1:
        files_idx = content.find(files_marker, idx)
        if files_idx != -1:
            insert_pos = content.find('\n', files_idx) + 1
            content = content[:insert_pos] + '\n'.join(sources_entries) + '\n' + content[insert_pos:]
    
    with open(PROJECT_FILE, 'w') as f:
        f.write(content)
    
    print(f"Updated {PROJECT_FILE}")

if __name__ == "__main__":
    main()
