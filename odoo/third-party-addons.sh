# Check if the repository directory exists
if [ ! -d "odoo-cloud-platform" ]; then
    git clone https://github.com/camptocamp/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
    cp -r odoo-cloud-platform/base_attachment_object_storage ${THIRD_PARTY_ADDONS}/base_attachment_object_storage
    cp -r odoo-cloud-platform/attachment_s3 ${THIRD_PARTY_ADDONS}/attachment_s3
fi

# Define the path to the manifest file
manifest_file_path="${THIRD_PARTY_ADDONS}/attachment_s3/__manifest__.py"

# Use Python to modify the manifest file
python3 -c "
filename = '${manifest_file_path}'

# Read the file content
with open(filename, 'r') as file:
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
    modified_manifest_lines.append(f'    \'{key}\': {repr(value)},\n')
modified_manifest_lines.append('}\n')

# Replace the manifest dictionary string in the content
lines[start_index:end_index + 1] = modified_manifest_lines

# Write the modified content back to the file
with open(filename, 'w') as file:
    file.writelines(lines)
"

echo "Modified $manifest_file_path"

# Optional: Cat the file to verify changes
cat $manifest_file_path