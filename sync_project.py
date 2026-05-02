import sys
import uuid
import os

def generate_id():
    return uuid.uuid4().hex[:24].upper()

project_path = 'ios/VeriCall.xcodeproj/project.pbxproj'
with open(project_path, 'r') as f:
    lines = f.readlines()

def add_file(file_name, group_name):
    # Check if already in project (simplified check)
    if any(f"/* {file_name} */" in line for line in lines if "isa = PBXFileReference" in line):
        # Even if file ref exists, check if it is in Sources build phase
        return

    file_ref_id = generate_id()
    build_file_id = generate_id()
    
    file_type = "sourcecode.swift"
    if file_name.endswith(".mlpackage"): file_type = "folder.mlpackage"
    elif file_name.endswith(".mlmodel"): file_type = "wrapper.mlmodel"
    elif file_name.endswith(".onnx"): file_type = "file"

    print(f"Adding {file_name} to {group_name}")

    # 1. PBXBuildFile
    for i, line in enumerate(lines):
        if '/* Begin PBXBuildFile section */' in line:
            lines.insert(i+1, f'\t\t{build_file_id} /* {file_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};\n')
            break

    # 2. PBXFileReference
    for i, line in enumerate(lines):
        if '/* Begin PBXFileReference section */' in line:
            lines.insert(i+1, f'\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {file_name}; sourceTree = "<group>"; }};\n')
            break

    # 3. Add to Group
    inside_group = False
    for i, line in enumerate(lines):
        if f'/* {group_name} */ = {{' in line and (i+1 < len(lines) and 'isa = PBXGroup;' in lines[i+1]):
            inside_group = True
        if inside_group and 'children = (' in line:
            lines.insert(i+1, f'\t\t\t\t{file_ref_id} /* {file_name} */,\n')
            break

    # 4. Sources Build Phase (only for code/models)
    if not file_name.endswith(".onnx"):
        inside_sources = False
        for i, line in enumerate(lines):
            if 'isa = PBXSourcesBuildPhase;' in line:
                inside_sources = True
            if inside_sources and 'files = (' in line:
                lines.insert(i+1, f'\t\t\t\t{build_file_id} /* {file_name} in Sources */,\n')
                break

# Scan directories
base_dir = "ios/VeriCall"
groups = ["App", "Models", "Services", "Views/Calling", "Views/Contacts", "Views/Components", "Views/Settings", "Utils"]

for group in groups:
    group_path = os.path.join(base_dir, group)
    if not os.path.exists(group_path): continue
    
    # Simpler group name for pbxproj search
    simple_group_name = group.split("/")[-1]
    
    for f in os.listdir(group_path):
        if f.endswith((".swift", ".mlpackage", ".mlmodel")):
            add_file(f, simple_group_name)

with open(project_path, 'w') as f:
    f.writelines(lines)
print("Project sync complete.")
