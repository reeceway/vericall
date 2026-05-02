import sys
import uuid
import os

def generate_id():
    return uuid.uuid4().hex[:24].upper()

project_path = 'ios/VeriCall.xcodeproj/project.pbxproj'
with open(project_path, 'r') as f:
    lines = f.readlines()

def add_file(file_name, path_in_project, group_name, is_ml_model=False):
    if any(file_name in line for line in lines):
        print(f"File {file_name} already present in project.")
        return

    file_ref_id = generate_id()
    build_file_id = generate_id()
    
    file_type = "folder.mlpackage" if file_name.endswith(".mlpackage") else "sourcecode.swift"
    if file_name.endswith(".mlmodel"): file_type = "wrapper.mlmodel"

    print(f"Adding {file_name} with IDs: file_ref={file_ref_id}, build_file={build_file_id}")

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
        if f'/* {group_name} */ = {{' in line and 'isa = PBXGroup;' in lines[i+1]:
            inside_group = True
        if inside_group and 'children = (' in line:
            lines.insert(i+1, f'\t\t\t\t{file_ref_id} /* {file_name} */,\n')
            break

    # 4. Sources Build Phase
    inside_sources = False
    for i, line in enumerate(lines):
        if 'isa = PBXSourcesBuildPhase;' in line:
            inside_sources = True
        if inside_sources and 'files = (' in line:
            lines.insert(i+1, f'\t\t\t\t{build_file_id} /* {file_name} in Sources */,\n')
            break

# Update Hemgg path
for i, line in enumerate(lines):
    if 'CC000102 /* HemggDeepfake.mlpackage */' in line and 'isa = PBXFileReference' in line:
        # Hemgg was moved into VeriCall/Models/
        # Since the Models group is already relative to VeriCall, and VeriCall group is relative to root...
        # Wait, if Hemgg is inside Models group, the path should just be HemggDeepfake.mlpackage if the group has its own path.
        pass

# Add new files
add_file("LocalVoiceVerifier.swift", "VeriCall/Services/LocalVoiceVerifier.swift", "Services")
add_file("VoiceEmbedder.mlpackage", "VeriCall/Models/VoiceEmbedder.mlpackage", "Models", True)
add_file("CloneDetector.mlmodel", "VeriCall/Models/CloneDetector.mlmodel", "Models", True)

with open(project_path, 'w') as f:
    f.writelines(lines)
print("Modified project.pbxproj successfully")
