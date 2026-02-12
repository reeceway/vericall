require 'xcodeproj'

project_path = 'VeriCall.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath(File.join('VeriCall', 'Models'), true)
file_ref = group.find_file_by_path('WavLMDeepfake.mlpackage')

if file_ref
  # Remove from Copy Bundle Resources (cleanup duplicate)
  resources_phase = target.resources_build_phase
  if resources_phase.files_references.include?(file_ref)
    resources_phase.remove_file_reference(file_ref)
    puts "Removed from Copy Bundle Resources"
  else
    puts "Not in Copy Bundle Resources"
  end

  # Ensure still in Compile Sources
  sources_phase = target.source_build_phase
  unless sources_phase.files_references.include?(file_ref)
    sources_phase.add_file_reference(file_ref)
    puts "Added to Compile Sources"
  else
    puts "Confirmed in Compile Sources"
  end

  project.save
  puts "Project saved."
else
  puts "Error: Could not find WavLMDeepfake.mlpackage file reference in project."
end
