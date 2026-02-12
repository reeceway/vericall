require 'xcodeproj'

project_path = 'VeriCall.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'VeriCall' }
group = project.main_group.find_subpath('VeriCall/Views', true)

# Add DeepfakeLabView.swift
file_name = 'DeepfakeLabView.swift'
file_ref = group.find_file_by_path(file_name) || group.new_file(file_name)

if target.source_build_phase.files_references.include?(file_ref)
  puts "#{file_name} already in compile sources"
else
  target.add_file_references([file_ref])
  puts "Added #{file_name} to compile sources"
end

project.save
puts "Project saved"
