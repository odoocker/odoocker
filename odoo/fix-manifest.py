import sys

# Define the path to the manifest file
manifest_file_path = sys.argv[1]

# Read the file content
with open(manifest_file_path, 'r') as file:
    lines = file.readlines()

# Find the start and end index of the manifest dictionary
start_index = next(i for i, line in enumerate(lines) if line.strip().startswith('{'))
end_index = next(i for i, line in enumerate(lines) if line.strip().endswith('}'))

# Construct and evaluate the manifest dictionary
manifest_dict = eval(''.join(lines[start_index:end_index + 1]))

# Modify the manifest dictionary
manifest_dict['installable'] = True
manifest_dict['auto_install'] = True

# Construct the modified manifest string
modified_manifest_lines = ['{\n']
for key, value in manifest_dict.items():
    modified_manifest_lines.append(f"    '{key}': {repr(value)},\n")
modified_manifest_lines.append('}\n')

# Replace the manifest dictionary string in the content
lines[start_index:end_index + 1] = modified_manifest_lines

# Write the modified content back to the file
with open(manifest_file_path, 'w') as file:
    file.writelines(lines)

print(f"Modified {manifest_file_path}")
