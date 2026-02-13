import sys
import uuid

def generate_id():
    return uuid.uuid4().hex[:24].upper()

project_path = 'ios/VeriCall.xcodeproj/project.pbxproj'
with open(project_path, 'r') as f:
    lines = f.readlines()

if any('Assets.xcassets' in line for line in lines):
    print("Assets already present")
    sys.exit(0)

file_ref_id = generate_id()
build_file_id = generate_id()

print(f"Adding Assets.xcassets with IDs: file_ref={file_ref_id}, build_file={build_file_id}")

# 1. PBXBuildFile
for i, line in enumerate(lines):
    if '/* Begin PBXBuildFile section */' in line:
        lines.insert(i+1, f'\t\t{build_file_id} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* Assets.xcassets */; }};\n')
        break

# 2. PBXFileReference
for i, line in enumerate(lines):
    if '/* Begin PBXFileReference section */' in line:
        lines.insert(i+1, f'\t\t{file_ref_id} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};\n')
        break

# 3. Main Group (VeriCall)
# Find group named "VeriCall" which is a PBXGroup
inside_group_block = False
target_group_found = False
for i, line in enumerate(lines):
    if '/* VeriCall */ = {' in line:
        # potential match, check if isa = PBXGroup is near
        # Look ahead 1 line
        if i+1 < len(lines) and 'isa = PBXGroup;' in lines[i+1]:
            inside_group_block = True
            
    if inside_group_block and 'children = (' in line:
        lines.insert(i+1, f'\t\t\t\t{file_ref_id} /* Assets.xcassets */,\n')
        target_group_found = True
        break

if not target_group_found:
    print("Warning: Could not find VeriCall PBXGroup")

# 4. Resources Build Phase
inside_resources = False
resources_found = False
for i, line in enumerate(lines):
    if 'isa = PBXResourcesBuildPhase;' in line:
        inside_resources = True
    if inside_resources and 'files = (' in line:
        lines.insert(i+1, f'\t\t\t\t{build_file_id} /* Assets.xcassets in Resources */,\n')
        resources_found = True
        break

if not resources_found:
    print("Warning: Could not find PBXResourcesBuildPhase")

with open(project_path, 'w') as f:
    f.writelines(lines)
print("Modified project.pbxproj successfully")
