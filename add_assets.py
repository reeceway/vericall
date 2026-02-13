import sys
import os
import uuid

def generate_id():
    return uuid.uuid4().hex[:24].upper()

def patch_project(project_path):
    file_name = "Assets.xcassets"
    file_ref_id = generate_id()
    build_file_id = generate_id()
    
    with open(project_path, 'r') as f:
        content = f.read()
        
    if file_name in content:
        print(f"{file_name} already in project")
        return

    # 1. PBXBuildFile
    build_file_entry = f'\t\t{build_file_id} /* {file_name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};\n'
    content = content.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n" + build_file_entry)

    # 2. PBXFileReference
    file_ref_entry = f'\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {file_name}; sourceTree = "<group>"; }};\n'
    content = content.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + file_ref_entry)

    # 3. Add to Main Group (VeriCall)
    # We look for main group or a Resources group.
    # We will try to add to 'VeriCall' group (which contains Info.plist etc)
    # Search for /* VeriCall */ = {
    
    group_name = "VeriCall"
    group_start_marker = f"/* {group_name} */ = {{"
    
    if group_start_marker in content:
        parts = content.split(group_start_marker)
        if len(parts) > 1:
            pre_group = parts[0] + group_start_marker
            post_group = parts[1]
            children_start = post_group.find("children = (")
            if children_start != -1:
                 insert_pos = children_start + len("children = (")
                 new_post_group = post_group[:insert_pos] + f"\n\t\t\t\t{file_ref_id} /* {file_name} */," + post_group[insert_pos:]
                 content = pre_group + new_post_group
            else:
                print("Could not find children in VeriCall group")
                return
    else:
        print(f"Could not find group {group_name}")
        return

    # 4. PBXResourcesBuildPhase
    # Find the resources build phase
    if "isa = PBXResourcesBuildPhase;" in content:
         sources_part = content.split("isa = PBXResourcesBuildPhase;")
         # Assume only one resources build phase for now or pick the first one
         pre_sources = sources_part[0] + "isa = PBXResourcesBuildPhase;"
         post_sources = sources_part[1]
         
         files_start = post_sources.find("files = (")
         if files_start != -1:
             insert_pos = files_start + len("files = (")
             new_post_sources = post_sources[:insert_pos] + f"\n\t\t\t\t{build_file_id} /* {file_name} in Resources */," + post_sources[insert_pos:]
             content = pre_sources + new_post_sources
         else:
             print("Could not find files in PBXResourcesBuildPhase")
             return

    with open(project_path, 'w') as f:
        f.write(content)
    print(f"Successfully added {file_name} to project")

if __name__ == "__main__":
    project = "ios/VeriCall.xcodeproj/project.pbxproj"
    patch_project(project)
