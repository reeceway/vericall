require 'xcodeproj'

project_path = 'VeriCall.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

group = project.main_group.find_subpath(File.join('VeriCall', 'Models'), true)
file_ref = group.find_file_by_path('WavLMDeepfake.mlpackage')

if file_ref
  puts "Found file ref: #{file_ref.path}"
else
  puts "File ref not found, looking for it in project..."
  # It might be in a different group or just at root level if added weirdly
  file_ref = project.files.find { |f| f.path == 'WavLMDeepfake.mlpackage' }
end


if file_ref
  # Add to Compile Sources (for Code Generation)
  sources_phase = target.source_build_phase
  unless sources_phase.files_references.include?(file_ref)
    sources_phase.add_file_reference(file_ref)
    puts "Added to Compile Sources"
  else
    puts "Already in Compile Sources"
  end

  # Add to Copy Bundle Resources (required for the model to load at runtime)
  resources_phase = target.resources_build_phase
  unless resources_phase.files_references.include?(file_ref)
    resources_phase.add_file_reference(file_ref)
    puts "Added to Copy Bundle Resources"
  else
    puts "Already in Copy Bundle Resources"
  end

  project.save
  puts "Project saved."
else
  puts "Error: Could not find WavLMDeepfake.mlpackage file reference in project."
end
