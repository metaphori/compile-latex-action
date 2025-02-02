#!/usr/bin/env ruby

require 'set'

def warn(file, message)
    puts "::error file={#{file}},title={Compilation failed for #{file}}::{#{message}}"
    puts "W: #{"Warning on file #{file}:\n#{message}".gsub(/\R/, "\nW: ")}"
end

command = ARGV[0] || "TEXINPUTS='.:.//' rubber --unsafe --inplace -d --synctex -s -W all"
verbose = ARGV[1].to_s.downcase == "true"
output_variable = ARGV[2] || 'LATEX_SUCCESSES'
texfilter = ARGV[3] || '*.tex'
limit = ARGV[4].to_i || 20
latex_packages_to_install = (ARGV[5] || "").split(/,/);

latex_packages_to_install.each do |p|
    cmd = "tlmgr install #{p}"
    outcmd = `#{cmd} 2>&1` 
    puts(outcmd) if verbose
end

initial_directory = File.expand_path('.') + '/'
puts "Working from #{initial_directory}"
puts "Using filter '#{texfilter}'"
tex_filters = texfilter.split(/ /).flat_map { |x| x.split(/,/) }.map { |f| initial_directory + f }
puts "Searching #{tex_filters}"
tex_files = Dir[*tex_filters]
puts "Found these tex files: #{tex_files}" # if verbose
magic_comment_matcher = /^\s*%\s*!\s*[Tt][Ee][xX]\s*root\s*=\s*(.*\.[Tt][Ee][xX]).*$/
tex_roots = tex_files.filter_map do |file|
    puts "Considering #{file}"
    text = File.read(file)
    match = text[magic_comment_matcher, 1]
    if match 
        puts("File #{file} matched a magic comment pointing to #{match}")
        directory = File.dirname(file)
        match = "#{directory}/#{match}"
        puts "The actual absolute file would be #{match}"
    end
    [file, match]
end
tex_ancillary, tex_roots = tex_roots.partition { | _, match | match }
puts "These files have been detected as ancillary: #{tex_ancillary.map { |file, match| file }}"
tex_roots = tex_roots.map(&:first)
tex_ancillary.each do |file, match|
    File.file?(match) && tex_roots << match ||
        warn(file, "#{file} declares its root to be #{match}, but such file does not exist.")
end
tex_roots = tex_roots.take(limit).to_set
puts "Detected (and limited) the following LaTeX roots: #{tex_roots}"
successes = Set[]
previous_successes = nil
failures = Set[]
until successes == tex_roots || successes == previous_successes do
    previous_successes = successes
    failures = Set[]
    (tex_roots - successes).each do |root|
        match = root.match(/^(.*)\/(.*\.[Tt][Ee][xX])$/)
        install_command = "texliveonfly -a '-synctex=1 -interaction=nonstopmode -shell-escape' '#{root}'"
        Dir.chdir(File.dirname(root))
        puts "Installing required packages via #{install_command}"
        output = `#{install_command} 2>&1`
        puts(output) if verbose
        puts "Compiling #{root} with: \"#{command} '#{root}'\""
        output << `#{command} '#{root}' 2>&1`
        puts(output) if verbose
        Dir.chdir(initial_directory)
        if $?.success? then
            successes << root
        else
            failures << [root, output]
        end
    end
end 
success_list = successes.map{ |it| it.sub(initial_directory, '') }

puts "::set-output name=successfully-compiled::#{success_list.join(',')}"
puts "::set-output name=compiled-files::#{
    success_list.map { |file_name| file_name.gsub(/^(.*)\.\w+$/) { "#{$1}.pdf" } }.join(',')
}"

heredoc_delimiter = 'EOF'
export = "#{output_variable}<<#{heredoc_delimiter}\n#{success_list.join("\n")}\n#{heredoc_delimiter}"
puts 'Generated variable output:'
puts export

github_environment = ENV['GITHUB_ENV']
if !success_list.empty? && github_environment then
    puts 'Detected actual GitHub Actions environment, running the export'
    File.open(github_environment, 'a') do |env|
        env.puts(export)
    end
    puts File.open(github_environment).read
end

failures.each do |file, output|
    warn(file, "failed to compile, output:\n#{output}")
end
exit failures.size
